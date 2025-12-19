// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {IInterestManager} from "./interfaces/IInterestManager.sol";

/**
 * @title   ReliqHYPE
 * @author  Reliq
 * @notice  Fixed-term, over-collateralised lending protocol that issues a yield-bearing ERC-20 token (relHYPE)
 *          backed 1:1 by a reserve token (kHYPE). Users can mint relHYPE by depositing kHYPE, redeem it at any
 *          time, or lock it as collateral to borrow kHYPE at a 99 % LTV. Positions become eligible for liquidation
 *          at the first midnight UTC after maturity. The protocol enforces an “up-only” price invariant: every
 *          interaction must increase or maintain the relHYPE/kHYPE exchange rate.
 *
 * @dev     Key design choices:
 *          - Single loan per address; expired loans are silently deleted.
 *          - Interest is pre-computed and collected up-front; no accrual.
 *          - Liquidations are processed per-day, burning collateral and removing debt.
 *          - Fees are split between LPs (70 %) and treasury (30 % by default).
 *          - masterMinter can raise the supply cap dynamically to allow unlimited expansion.
 *
 *          Inherits:
 *          - ERC20Burnable: standard burnable token implementation.
 *          - Ownable: administrative functions restricted to deployer.
 *          - ReentrancyGuard: re-entrancy protection on all external entry-points.
 */
contract ReliqHYPE is ERC20Burnable, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Represents a user’s outstanding loan position
    /// @dev Stored per user address; collateral is denominated in relHYPE, borrowed in backing token (kHYPE)
    /// @param collateral Amount of relHYPE tokens locked as collateral
    /// @param borrowed Amount of backing token debt outstanding
    /// @param endDate Timestamp (midnight UTC) when the loan becomes eligible for liquidation
    /// @param numberOfDays Original loan duration in days (used for interest calculations)
    struct Loan {
        uint256 collateral;
        uint256 borrowed;
        uint256 endDate;
        uint256 numberOfDays;
    }

    IERC20 public immutable backingToken;

    uint256 public constant LTV_BPS = 9900; // 99%
    uint256 public constant DUST = 1000;

    // Fee parameters
    uint256 public buyFeeBPS = 300; // 3% fee
    uint256 public sellFeeBPS = 300; // 3% fee
    uint256 public buyLeverageFeeBPS = 100; // Mint fee on leverage actions.
    uint256 public flashCloseFeeBPS = 100; // 1% flash close fee.
    uint256 public protocolFeeShare = 3000; // 30% of fees go to protocol treasury.
    uint256 public constant FEE_BASE_BPS = 10000; // Base for fee calculations.

    /// @notice Address that receives protocol fees
    address public treasury;

    /// @notice Contract responsible for managing interest rates
    IInterestManager public interestManager;

    // Global state variables

    /// @notice Indicates whether the contract has been started
    bool public start = false;
    /// @notice Maximum amount of relHYPE tokens that can be minted
    uint256 public maxMintable = 0;
    /// @notice Total amount of relHYPE tokens minted
    uint256 public assetMinted = 0;
    /// @notice Total amount of relHYPE tokens locked as collateral
    uint256 public totalCollateral = 0;
    /// @notice Total amount of backing token debt outstanding
    uint256 public totalBorrowed = 0;
    /// @notice Last recorded price of relHYPE token in backing token terms
    uint256 public lastPrice = 0;

    /// @notice Address that is authorized to mint relHYPE tokens
    address public masterMinter;

    // Lending state
    mapping(address => Loan) public Loans;
    mapping(uint256 => uint256) public BorrowedByDate;
    mapping(uint256 => uint256) public CollateralByDate;
    /// @notice Last timestamp (midnight UTC) when a loan was liquidated. In reality, this is the `next` liquidation date.
    uint256 public lastLiquidationDate;

    // Events
    event Started(bool started);

    event Buy(address indexed user, uint256 amountIn, uint256 amountOut);
    event Sell(address indexed user, uint256 amountIn, uint256 amountOut);

    event Leverage(address indexed user, uint256 collateral, uint256 borrowed);
    event Borrow(address indexed user, uint256 collateral, uint256 borrow);
    event RemoveCollateral(address indexed user, uint256 collateralRemoved, uint256 finalCollateral);
    event Repay(address indexed user, uint256 amountRepaid, uint256 finalBorrowed);
    event ClosePosition(address indexed user);
    event FlashClosePosition(address indexed user);
    event ExtendLoan(address indexed user, uint256 numberOfDays, uint256 newEndDate);
    event Liquidate(uint256 time, uint256 collateral, uint256 borrowed);

    event LoanBookUpdate(
        uint256 collateralByDate, uint256 borrowedByDate, uint256 totalBorrowed, uint256 totalCollateral
    );
    event UserLoanBookUpdate(address indexed user, Loan loan);
    event LoanDeleted(address indexed user);

    event PricePulse(uint256 time, uint256 price, uint256 volumeInBacking);
    event InterestManagerUpdated(address manager);

    constructor(IERC20 backing) ERC20("Reliq HYPE", "relHYPE") Ownable(msg.sender) {
        backingToken = backing;
    }

    function setStart(uint256 amount, uint256 burnAmount) public onlyOwner nonReentrant {
        require(amount > 0, "reHYPE: amount must be greater than 0");
        require(burnAmount <= amount, "reHYPE: burn amount cannot be higher than mint amount");
        require(treasury != address(0), "reHYPE: treasury not set");
        require(!start && maxMintable == 0, "reHYPE: already started");

        start = true;
        // Sets the initial liquidation date to the NEXT midnight UTC.
        lastLiquidationDate = getMidnightTimestamp(block.timestamp);

        // Set the max mintable to the initial mint amount, blocking further minting until cap is explicitly raised.
        maxMintable = amount;

        backingToken.safeTransferFrom(msg.sender, address(this), amount);
        mint(msg.sender, amount);
        _transfer(msg.sender, 0x000000000000000000000000000000000000dEaD, burnAmount);

        lastPrice = AssetToBackingFloor(1 ether);

        emit Started(true);
        emit MaxMintableUpdated(maxMintable);
        emit PricePulse(block.timestamp, lastPrice, getBacking());
    }

    /* 
        Core Protocol Functions
    */

    /// @notice Mint relHYPE tokens by depositing the backing token (kHYPE).
    /// @dev Enforces buy‐fee, updates price invariant, and allows masterMinter to breach maxMintable.
    /// @param receiver Address that will receive the newly minted relHYPE.
    /// @param amountInBacking Exact quantity of backing token the caller is sending.
    function buy(address receiver, uint256 amountInBacking) external nonReentrant {
        require(start, "reHYPE: trading not started");
        require(receiver != address(0x0), "reHYPE: 0x0 forbidden receiver");

        liquidate(); // Ensure any overdue positions are processed before price calculation.

        // Compute relHYPE amount before fee (floor rounding favors the protocol).
        uint256 assetAmountPreFee = BackingToAssetFloor(amountInBacking);

        // Apply buy‐fee: assetToMintPostFee = assetAmountPreFee * (1 - buyFeeBPS / FEE_BASE_BPS).
        uint256 assetToMintPostFee = Math.mulDiv(assetAmountPreFee, FEE_BASE_BPS - buyFeeBPS, FEE_BASE_BPS);

        // Protocol’s share of the buy‐fee (in backing token).
        uint256 protocolFee = Math.mulDiv(amountInBacking, buyFeeBPS * protocolFeeShare, FEE_BASE_BPS * FEE_BASE_BPS);
        require(protocolFee >= DUST, "reHYPE: buy fee below minimum"); // Prevents dust spam.

        // masterMinter can dynamically raise maxMintable to allow unlimited supply expansion.
        if (msg.sender == masterMinter) {
            if (assetMinted + assetToMintPostFee > maxMintable) {
                maxMintable = assetMinted + assetToMintPostFee;
                emit MaxMintableUpdated(maxMintable);
            }
        }

        // Transfer backing token from caller and mint relHYPE to receiver.
        backingToken.safeTransferFrom(msg.sender, address(this), amountInBacking);
        mint(receiver, assetToMintPostFee);

        // Forward protocol fee to treasury.
        backingToken.safeTransfer(treasury, protocolFee);

        // Enforce price‐up‐only invariant and emit price pulse.
        _upOnly(amountInBacking);
        emit Buy(receiver, amountInBacking, assetToMintPostFee);
    }

    /// @notice Burns relHYPE tokens and returns backing token to the caller, minus sell fee.
    /// @dev    Enforces the protocol’s “up-only” price invariant after every sale.
    /// @param  amountInAsset Exact quantity of relHYPE the caller wants to redeem.
    function sell(uint256 amountInAsset) external nonReentrant {
        require(start, "reHYPE: trading not started");
        liquidate(); // Ensure any overdue positions are processed before price calculation.

        // Floor-round conversion to guarantee the protocol never over-pays.
        uint256 backingTokenAmount = AssetToBackingFloor(amountInAsset);

        // Net amount user receives after sell fee is deducted.
        uint256 backingPostFee = Math.mulDiv(backingTokenAmount, FEE_BASE_BPS - sellFeeBPS, FEE_BASE_BPS);

        // Protocol’s share of the sell fee (in backing token).
        uint256 protocolFee =
            Math.mulDiv(backingTokenAmount, sellFeeBPS * protocolFeeShare, FEE_BASE_BPS * FEE_BASE_BPS);
        require(protocolFee >= DUST, "reHYPE: sell fee below minimum"); // Prevents dust spam.

        _burn(msg.sender, amountInAsset); // Burn caller’s relHYPE.
        backingToken.safeTransfer(msg.sender, backingPostFee); // Send net proceeds to caller.
        backingToken.safeTransfer(treasury, protocolFee); // Forward protocol fee to treasury.

        // Enforce price-up-only invariant and emit price pulse.
        _upOnly(backingTokenAmount);
        emit Sell(msg.sender, amountInAsset, backingPostFee);
    }

    /// @notice Calculates the interest fee for a given borrowed amount over a specified number of days.
    /// @dev Uses the interest rate provided by the interestManager for the caller.
    /// @param borrowed The amount of backing token borrowed.
    /// @param numberOfDays The loan duration in days.
    /// @return interestFee The calculated interest fee in backing token units.
    function getInterestFee(uint256 borrowed, uint256 numberOfDays) public view returns (uint256 interestFee) {
        uint256 rateBPS = interestManager.getInterestRateBPS(msg.sender);
        interestFee = Math.mulDiv(borrowed, rateBPS * numberOfDays, FEE_BASE_BPS * 365);
    }

    /// @notice Opens a levered long position: caller indicates target exposure, the protocol calculates the necessary payment and opens the desired position
    /// @dev The caller ends up with a loan position that is multiple times larger than what they paid to have amplified exposure to the collateral asset's yield.
    ///      The position is subject to buyLeverageFeeBPS and pro-rata interest. Fees are taken in backing token; collateral is minted net of those fees.
    ///      Liquidation can occur after `endDate`. Only one open loan per address is allowed.
    /// @param amountIn Target exposure indicated by the caller.
    /// @param numberOfDays Loan tenor; 1-365 days. Position becomes eligible for liquidation at the first midnight ≥ block.timestamp + numberOfDays * 1 days.
    function leverage(uint256 amountIn, uint256 numberOfDays) public nonReentrant loanTenureInRange(numberOfDays) {
        require(start, "reHYPE: trading not started");
        liquidate(); // Ensure overdue positions are processed before we price collateral.

        // Single-loan policy: delete expired loans silently, then enforce no active loan.
        Loan memory userLoan = Loans[msg.sender];
        if (userLoan.borrowed != 0) {
            if (isLoanExpired(msg.sender)) {
                delete Loans[msg.sender];
                emit LoanDeleted(msg.sender);
            }
            require(Loans[msg.sender].borrowed == 0, "reHYPE: existing loan must be closed");
        }

        // Compute expiry timestamp (next midnight UTC).
        uint256 endDate = getMidnightTimestamp(block.timestamp + (numberOfDays * 1 days));

        /* ----------------------------------------------------------
         * 1. Fee arithmetic (all in backing token)
         * ---------------------------------------------------------- */
        uint256 leverageBuyFee = Math.mulDiv(amountIn, buyLeverageFeeBPS, FEE_BASE_BPS); // mint fee
        uint256 borrowFee = getInterestFee(amountIn, numberOfDays); // interest for the full tenor
        uint256 totalLeverageFee = leverageBuyFee + borrowFee;

        uint256 protocolFee = Math.mulDiv(totalLeverageFee, protocolFeeShare, FEE_BASE_BPS);
        require(protocolFee >= DUST, "reHYPE: leverage fee below minimum"); // anti-spam

        /* ----------------------------------------------------------
         * 2. Post-fee deposit split
         * ---------------------------------------------------------- */
        uint256 amountInPostFee = amountIn - totalLeverageFee; // backing token left after fees
        // Over-collateral required: 1 % of post-fee target exposure (LTV 99 %).
        uint256 overCollatAmount = Math.mulDiv(amountInPostFee, FEE_BASE_BPS - LTV_BPS, FEE_BASE_BPS);
        // Total the caller must send: fees + over-collateral.
        // This is the key to leverage, as the user pays a tiny fraction of the target exposure to get a large loan position.
        uint256 finalToPay = totalLeverageFee + overCollatAmount;

        // Borrow amount: 99 % of post-fee deposit (LTV applied to backing, not collateral).
        uint256 borrowAmount = Math.mulDiv(amountInPostFee, LTV_BPS, FEE_BASE_BPS);
        // Collateral to mint: relHYPE tokens representing the post-fee deposit (floor rounding).
        uint256 collateralToMint = BackingToAssetFloor(amountInPostFee);

        /* ----------------------------------------------------------
         * 3. State updates & transfers
         * ---------------------------------------------------------- */
        addLoansByDate(borrowAmount, collateralToMint, endDate);
        Loans[msg.sender] =
            Loan({collateral: collateralToMint, borrowed: borrowAmount, endDate: endDate, numberOfDays: numberOfDays});

        // Mint collateral to contract (locked), pull backing token from user, forward protocol fee.
        mint(address(this), collateralToMint);
        backingToken.safeTransferFrom(msg.sender, address(this), finalToPay);
        backingToken.safeTransfer(treasury, protocolFee);

        /* ----------------------------------------------------------
         * 4. Events & price invariant
         * ---------------------------------------------------------- */
        emit Leverage(msg.sender, collateralToMint, borrowAmount);
        emit UserLoanBookUpdate(msg.sender, Loans[msg.sender]);

        // Enforce up-only price movement; `amountIn` is the gross backing flow captured.
        _upOnly(amountIn);
    }

    /**
     * @notice Opens a new fixed-term loan by locking relHYPE collateral and receiving backing-token liquidity.
     * @dev    The caller must already hold relHYPE; no leverage is applied (LTV is enforced through collateral
     *         rounding only). Interest and protocol fees are deducted from the gross borrow amount. The position
     *         becomes eligible for liquidation at the first midnight UTC after term on or after `block.timestamp + numberOfDays`.
     *         Only one open loan per address is allowed; any expired loan is silently deleted before a new one is created.
     * @param amountToBorrow Gross quantity of backing token the caller wants to receive (before interest & fees).
     * @param numberOfDays   Loan tenor in days (1–365). Used to compute interest and the liquidation date.
     */
    function borrow(uint256 amountToBorrow, uint256 numberOfDays) public nonReentrant loanTenureInRange(numberOfDays) {
        // Process any overdue positions to keep global books consistent before we read state.
        liquidate();

        // If caller has an expired loan, silently delete it so the single-loan invariant is satisfied.
        if (isLoanExpired(msg.sender)) {
            delete Loans[msg.sender];
            emit LoanDeleted(msg.sender);
        }

        require(amountToBorrow > 0, "reHYPE: amount must be greater than 0");
        require(Loans[msg.sender].borrowed == 0, "reHYPE: existing loan must be closed");

        // Compute maturity timestamp (next midnight UTC).
        uint256 endDate = getMidnightTimestamp(block.timestamp + (numberOfDays * 1 days));

        // Interest is charged on the gross amount; protocol fee is a share of that interest.
        uint256 interestFee = getInterestFee(amountToBorrow, numberOfDays);
        uint256 protocolFee = Math.mulDiv(interestFee, protocolFeeShare, FEE_BASE_BPS);
        require(protocolFee >= DUST, "reHYPE: borrow fee below minimum"); // Prevent dust spam.

        // Collateral required: round **up** when converting backing→asset so the protocol is always over-collateralised.
        uint256 requiredCollateralInAsset = BackingToAssetCeil(amountToBorrow);

        // Effective debt posted to books: 99 % of gross borrow (LTV applied).
        uint256 effectiveBorrowAmount = Math.mulDiv(amountToBorrow, LTV_BPS, FEE_BASE_BPS);

        // Net proceeds sent to user: after interest is subtracted from the effective borrow.
        uint256 borrowAmountPostFee = effectiveBorrowAmount - interestFee;

        // Write loan to storage and update global tracking by liquidation date.
        Loans[msg.sender] = Loan({
            collateral: requiredCollateralInAsset,
            borrowed: effectiveBorrowAmount,
            endDate: endDate,
            numberOfDays: numberOfDays
        });
        addLoansByDate(effectiveBorrowAmount, requiredCollateralInAsset, endDate);

        // Pull collateral from user, push net liquidity to user, forward protocol fee to treasury.
        _transfer(msg.sender, address(this), requiredCollateralInAsset);
        backingToken.safeTransfer(msg.sender, borrowAmountPostFee);
        backingToken.safeTransfer(treasury, protocolFee);

        emit Borrow(msg.sender, requiredCollateralInAsset, effectiveBorrowAmount);
        emit UserLoanBookUpdate(msg.sender, Loans[msg.sender]);

        // Enforce price-up-only invariant; interest fee represents the economic flow captured by the protocol.
        _upOnly(interestFee);
    }

    /**
     * @notice Increases an existing loan by borrowing additional backing tokens while keeping the same maturity date.
     * @dev    Interest is charged pro-rata for the remaining days until maturity. If the user’s current collateral
     *         (after applying the 99 % LTV haircut) is insufficient to cover the new borrow, additional collateral
     *         must be supplied. Protocol fees are forwarded to the treasury and the price-up-only invariant is enforced.
     * @param  amountToBorrow Gross amount of additional backing token the caller wants to receive (before interest & fees).
     */
    function borrowMore(uint256 amountToBorrow) public nonReentrant {
        require(!isLoanExpired(msg.sender), "reHYPE: No active loan");
        require(amountToBorrow > 0, "reHYPE: amount must be greater than 0");
        liquidate(); // Ensure any overdue positions are processed before we read state.

        // Load existing loan state.
        uint256 userBorrowed = Loans[msg.sender].borrowed;
        uint256 userCollateral = Loans[msg.sender].collateral;
        uint256 endDate = Loans[msg.sender].endDate;

        // Compute remaining tenor in days (floor) from next midnight UTC to maturity.
        uint256 nextMidnight = getMidnightTimestamp(block.timestamp);
        uint256 newBorrowTenure = (endDate - nextMidnight) / 1 days;

        // Compute interest and protocol fee on the new borrow.
        uint256 interestFee = getInterestFee(amountToBorrow, newBorrowTenure);
        uint256 protocolFee = Math.mulDiv(interestFee, protocolFeeShare, FEE_BASE_BPS);

        /* ----------------------------------------------------------
         * Collateral check: existing collateral (after 99 % LTV) must
         * cover existing + new borrow. Shortfall ⇒ caller tops up.
         * ---------------------------------------------------------- */
        // Collateral already backing the existing borrowed amount (floor rounding).
        uint256 existingCollateralUsed = BackingToAssetFloor(userBorrowed);
        // Collateral headroom at 99 % LTV: collateral * 0.99 - existingCollateralUsed.
        uint256 excessCollateral = Math.mulDiv(userCollateral, LTV_BPS, FEE_BASE_BPS) - existingCollateralUsed;

        // Collateral required to secure the new borrow (ceil rounding ⇒ over-collateralised).
        uint256 collateralRequiredForNewBorrow = BackingToAssetCeil(amountToBorrow);
        // Deficit to be supplied by user; zero if excessCollateral is enough.
        uint256 collateralDeficit =
            collateralRequiredForNewBorrow > excessCollateral ? collateralRequiredForNewBorrow - excessCollateral : 0;

        // Effective new debt posted to books: 99 % of gross borrow (LTV applied).
        uint256 effectiveNewBorrow = Math.mulDiv(amountToBorrow, LTV_BPS, FEE_BASE_BPS);

        // Update loan storage.
        uint256 netUserCollateral = userCollateral + collateralDeficit;
        uint256 netUserBorrow = userBorrowed + effectiveNewBorrow;
        Loans[msg.sender] = Loan({
            collateral: netUserCollateral,
            borrowed: netUserBorrow,
            endDate: endDate,
            numberOfDays: newBorrowTenure
        });
        addLoansByDate(effectiveNewBorrow, collateralDeficit, endDate);

        // Transfer collateral deficit (if any) from user to contract.
        if (collateralDeficit != 0) {
            _transfer(msg.sender, address(this), collateralDeficit);
        }

        // Send net proceeds (after interest) to user and forward protocol fee to treasury.
        backingToken.safeTransfer(msg.sender, effectiveNewBorrow - interestFee);
        backingToken.safeTransfer(treasury, protocolFee);

        emit Borrow(msg.sender, collateralDeficit, effectiveNewBorrow);
        emit UserLoanBookUpdate(msg.sender, Loans[msg.sender]);

        // Enforce price-up-only invariant; interest fee represents economic value captured.
        _upOnly(interestFee);
    }

    /// @notice Allows a borrower to withdraw excess collateral while keeping the loan healthy.
    /// @dev    Caller must have an active, non-expired loan. After removal, the remaining collateral
    ///         must still satisfy the 99 % LTV requirement (i.e. 1 % over-collateralisation).
    ///         Global liquidation books are updated and the price-up-only invariant is enforced.
    /// @param  collateralToRemove Exact amount of relHYPE collateral to unlock and transfer back to caller.
    function removeCollateral(uint256 collateralToRemove) public nonReentrant {
        require(!isLoanExpired(msg.sender), "reHYPE: No active loan");
        require(collateralToRemove > 0, "reHYPE: amount must be greater than 0");
        liquidate(); // Ensure any overdue positions are processed before we read state.

        uint256 userCollateral = Loans[msg.sender].collateral;
        uint256 userBorrowed = Loans[msg.sender].borrowed;

        // After removal, remaining collateral must still back the full borrowed amount at 99 % LTV.
        require(
            Math.mulDiv(AssetToBackingFloor(userCollateral - collateralToRemove), LTV_BPS, FEE_BASE_BPS) >= userBorrowed,
            "reHYPE: collateral not sufficient"
        );

        // Update loan and global books.
        Loans[msg.sender].collateral = userCollateral - collateralToRemove;
        subLoansByDate(0, collateralToRemove, Loans[msg.sender].endDate);

        // Unlock and return collateral to user.
        _transfer(address(this), msg.sender, collateralToRemove);

        emit RemoveCollateral(msg.sender, collateralToRemove, Loans[msg.sender].collateral);
        emit UserLoanBookUpdate(msg.sender, Loans[msg.sender]);

        // Enforce price-up-only invariant; no new backing flow ⇒ amount = 0.
        _upOnly(0);
    }

    /**
     * @notice Partially repays an active loan by sending backing tokens to the contract.
     * @dev    Caller must have a non-expired loan and the repayment amount must be
     *         greater than zero and strictly less than the outstanding borrowed amount.
     *         Global books are updated atomically and the price-up-only invariant is
     *         enforced with zero new backing flow.
     * @param  amount Exact quantity of backing token to repay.
     */
    function repay(uint256 amount) public nonReentrant {
        require(!isLoanExpired(msg.sender), "reHYPE: No active loan");
        require(amount > 0 && amount < Loans[msg.sender].borrowed, "reHYPE: invalid repay amount");

        // Pull repayment from caller into contract.
        backingToken.safeTransferFrom(msg.sender, address(this), amount);

        // Update local and global debt tracking.
        uint256 borrowed = Loans[msg.sender].borrowed;
        uint256 newBorrow = borrowed - amount;
        Loans[msg.sender].borrowed = newBorrow;
        subLoansByDate(amount, 0, Loans[msg.sender].endDate);

        emit Repay(msg.sender, amount, newBorrow);
        emit UserLoanBookUpdate(msg.sender, Loans[msg.sender]);

        // Enforce price-up-only invariant; no new economic value captured.
        _upOnly(0);
    }

    /**
     * @notice Closes an active loan by repaying the full outstanding debt and reclaiming all locked collateral.
     * @dev    Caller must have a non-expired loan. The full borrowed amount (in backing token) is transferred
     *         from the caller into the contract, and the entire collateral (in relHYPE) is returned to the caller.
     *         Global liquidation books are updated atomically, the loan record is deleted, and the price-up-only
     *         invariant is enforced with zero new backing flow.
     */
    function closePosition() public nonReentrant {
        require(!isLoanExpired(msg.sender), "reHYPE: No active loan");

        // Cache loan state to avoid multiple storage reads.
        uint256 collateral = Loans[msg.sender].collateral;
        uint256 borrowed = Loans[msg.sender].borrowed;

        // Transfer outstanding debt from borrower into contract.
        backingToken.safeTransferFrom(msg.sender, address(this), borrowed);
        // Return locked collateral to borrower.
        _transfer(address(this), msg.sender, collateral);

        // Update global liquidation books and delete user loan.
        subLoansByDate(borrowed, collateral, Loans[msg.sender].endDate);
        delete Loans[msg.sender];
        emit LoanDeleted(msg.sender);

        emit ClosePosition(msg.sender);
        // Emit after deletion; loan struct is zeroed, signalling "no active loan".
        emit UserLoanBookUpdate(msg.sender, Loans[msg.sender]);
        // Enforce price-up-only invariant; no new economic value captured.
        _upOnly(0);
    }

    /**
     * @notice Closes an active loan in a single atomic transaction without requiring the caller to pre-fund repayment.
     * @dev    The protocol burns the caller’s locked relHYPE collateral, converts it to backing token at the current
     *         oracle price (ceil rounding), deducts a 1 % flash-close fee, repays the outstanding debt, and forwards
     *         the surplus (if any) to the caller. The caller must have a non-expired loan and sufficient collateral
     *         to cover the debt plus fee. Global liquidation books are updated, the loan record is deleted, and the
     *         price-up-only invariant is enforced with the borrowed amount as the captured economic flow.
     */
    function flashClosePosition() public nonReentrant {
        require(!isLoanExpired(msg.sender), "reHYPE: No active loan");
        liquidate(); // Ensure any overdue positions are processed before we price collateral.

        // Cache loan state to avoid multiple storage reads.
        uint256 collateral = Loans[msg.sender].collateral;
        uint256 borrowed = Loans[msg.sender].borrowed;

        // Convert collateral to backing token using ceil rounding to guarantee protocol solvency.
        uint256 collateralInBacking = AssetToBackingCeil(collateral);

        // Compute flash-close fee (1 % of collateral value) and protocol’s share.
        uint256 operationFee = Math.mulDiv(collateralInBacking, flashCloseFeeBPS, FEE_BASE_BPS);
        uint256 protocolFee = Math.mulDiv(operationFee, protocolFeeShare, FEE_BASE_BPS);

        // Net collateral after fee must cover the outstanding debt.
        uint256 collateralInBackingPostFee = collateralInBacking - operationFee;
        require(collateralInBackingPostFee >= borrowed, "reHYPE: collateral not sufficient");

        // Surplus backing token returned to caller.
        uint256 toUser = collateralInBackingPostFee - borrowed;

        // Update global liquidation books and delete user loan.
        subLoansByDate(borrowed, collateral, Loans[msg.sender].endDate);
        delete Loans[msg.sender];
        emit LoanDeleted(msg.sender);

        // Burn the locked collateral and transfer proceeds to caller and treasury.
        _burn(address(this), collateral);
        backingToken.safeTransfer(msg.sender, toUser);
        backingToken.safeTransfer(treasury, protocolFee);

        emit FlashClosePosition(msg.sender);
        // Emit after deletion; loan struct is zeroed, signalling "no active loan".
        emit UserLoanBookUpdate(msg.sender, Loans[msg.sender]);

        // Enforce price-up-only invariant; borrowed amount represents economic value captured.
        _upOnly(borrowed);
    }

    /**
     * @notice Extends an active loan’s maturity by a user-specified number of days.
     * @dev    Interest for the extension period is charged in-full at the time of the call.
     *         The caller’s collateral remains locked; only the end-date and internal
     *         tenure counter are updated. Global liquidation books are migrated from the
     *         old maturity bucket to the new one. Reverts if the loan is expired, if
     *         the extension would push total tenure beyond 365 days, or if the interest
     *         payment is not provided.
     * @param  numberOfDays Days to extend the loan; must be > 0 and result in ≤ 365 total days.
     * @return interestFee  Total interest (in backing token) charged for the extension.
     */
    function extendLoan(uint256 numberOfDays) public nonReentrant returns (uint256) {
        require(!isLoanExpired(msg.sender), "reHYPE: No active loan");
        require(numberOfDays > 0, "reHYPE: numberOfDays must be greater than 0");

        liquidate(); // Bring liquidation state up-to-date before any book-keeping.

        // Cache loan memory to avoid repeated SLOADs.
        uint256 oldEndDate = Loans[msg.sender].endDate;
        uint256 collateral = Loans[msg.sender].collateral;
        uint256 borrowed = Loans[msg.sender].borrowed;
        uint256 _loanTenure = Loans[msg.sender].numberOfDays;

        // Compute new maturity and enforce ≤ 365-day total tenure.
        uint256 newEndDate = oldEndDate + (numberOfDays * 1 days);
        require((newEndDate - block.timestamp) / 1 days < 366, "reHYPE: Loan tenure must be less than 366 days");

        // Calculate interest for the extension period; caller must pay in full.
        uint256 interestFee = getInterestFee(borrowed, numberOfDays);
        backingToken.safeTransferFrom(msg.sender, address(this), interestFee);

        // Forward protocol’s share of the interest to treasury.
        uint256 protocolFee = Math.mulDiv(interestFee, protocolFeeShare, FEE_BASE_BPS);
        backingToken.safeTransfer(treasury, protocolFee);

        // Migrate liquidation buckets: remove from old date, add to new date.
        subLoansByDate(borrowed, collateral, oldEndDate);
        addLoansByDate(borrowed, collateral, newEndDate);

        // Update user loan storage.
        Loans[msg.sender].endDate = newEndDate;
        Loans[msg.sender].numberOfDays = _loanTenure + numberOfDays;

        emit ExtendLoan(msg.sender, numberOfDays, newEndDate);
        emit UserLoanBookUpdate(msg.sender, Loans[msg.sender]);

        // Enforce price-up-only invariant; interest payment represents new economic flow.
        _upOnly(interestFee);

        return interestFee;
    }

    /**
     * @notice Processes all overdue loans whose maturity date has passed.
     * @dev Iterates from the last processed liquidation date up to the current
     *      block timestamp, summing collateral and borrowed amounts for each
     *      elapsed day. Collateral is burned and removed from global totals;
     *      borrowed amounts are simply removed from global totals. Emits a
     *      single Liquidate event for the last processed day.
     */
    function liquidate() public {
        uint256 borrowed;
        uint256 collateral;

        // Accumulate collateral & debt for every elapsed day since last liquidation
        while (lastLiquidationDate < block.timestamp) {
            collateral += CollateralByDate[lastLiquidationDate];
            borrowed += BorrowedByDate[lastLiquidationDate];
            lastLiquidationDate += 1 days;
        }

        // Burn locked collateral and update global counters
        if (collateral != 0) {
            totalCollateral -= collateral;
            _burn(address(this), collateral);
        }

        // Remove liquidated debt from global totals; emit once for the last processed day
        if (borrowed != 0) {
            totalBorrowed -= borrowed;
            emit Liquidate(lastLiquidationDate - 1 days, collateral, borrowed);
        }
    }
    /* 
        ERC-20 Functions
    */

    function mint(address to, uint256 value) private {
        require(to != address(0), "reHYPE: mint to the zero address");
        assetMinted += value;
        require(assetMinted <= maxMintable, "reHYPE: exceeds max mintable");
        _mint(to, value);
    }

    /* 
        Utility Functions
    */
    function getMidnightTimestamp(uint256 date) public pure returns (uint256) {
        uint256 midnightTimestamp = date - (date % 86400); // Subtracting the remainder when divided by the number of seconds in a day (86400)
        return midnightTimestamp + 1 days;
    }

    function getBacking() public view returns (uint256) {
        return backingToken.balanceOf(address(this)) + totalBorrowed;
    }

    function BackingToAssetFloor(uint256 amountInBacking) public view returns (uint256) {
        return Math.mulDiv(amountInBacking, totalSupply(), getBacking());
    }

    function AssetToBackingFloor(uint256 amountInAsset) public view returns (uint256) {
        return Math.mulDiv(amountInAsset, getBacking(), totalSupply());
    }

    function BackingToAssetCeil(uint256 amountInBacking) public view returns (uint256) {
        return Math.mulDiv(amountInBacking, totalSupply(), getBacking(), Math.Rounding.Ceil);
    }

    function AssetToBackingCeil(uint256 amountInAsset) public view returns (uint256) {
        return Math.mulDiv(amountInAsset, getBacking(), totalSupply(), Math.Rounding.Ceil);
    }

    function addLoansByDate(uint256 borrowed, uint256 collateral, uint256 date) private {
        CollateralByDate[date] = CollateralByDate[date] + collateral;
        BorrowedByDate[date] = BorrowedByDate[date] + borrowed;
        totalBorrowed = totalBorrowed + borrowed;
        totalCollateral = totalCollateral + collateral;
        emit LoanBookUpdate(CollateralByDate[date], BorrowedByDate[date], totalBorrowed, totalCollateral);
    }

    function subLoansByDate(uint256 borrowed, uint256 collateral, uint256 date) private {
        CollateralByDate[date] = CollateralByDate[date] - collateral;
        BorrowedByDate[date] = BorrowedByDate[date] - borrowed;
        totalBorrowed = totalBorrowed - borrowed;
        totalCollateral = totalCollateral - collateral;
        emit LoanBookUpdate(CollateralByDate[date], BorrowedByDate[date], totalBorrowed, totalCollateral);
    }

    function getLoansExpiringByDate(uint256 date) public view returns (uint256, uint256) {
        return (BorrowedByDate[getMidnightTimestamp(date)], CollateralByDate[getMidnightTimestamp(date)]);
    }

    function getLoanByAddress(address _address) public view returns (uint256, uint256, uint256) {
        if (Loans[_address].endDate >= block.timestamp) {
            return (Loans[_address].collateral, Loans[_address].borrowed, Loans[_address].endDate);
        } else {
            return (0, 0, 0);
        }
    }

    function isLoanExpired(address _address) public view returns (bool) {
        return Loans[_address].endDate < block.timestamp;
    }

    /* 
        Protocol Config Functions (Only Owner)
    */

    event BuyFeeUpdated(uint256 feeBPS);
    event SellFeeUpdated(uint256 feeBPS);
    event LeverageBuyFeeUpdated(uint256 feeBPS);
    event FlashCloseFeeUpdated(uint256 feeBPS);
    event ProtocolFeeShareUpdated(uint256 feeBPS);
    event TreasuryUpdated(address treasury);
    event MasterMinterUpdated(address minter);
    event MaxMintableUpdated(uint256 maxMintable);

    function setBuyFee(uint256 _fee) external onlyOwner {
        require(_fee <= 1000, "reHYPE: fee too high"); // 10%
        require(_fee >= 5, "reHYPE: fee too low"); // 0.05%
        buyFeeBPS = _fee;
        emit BuyFeeUpdated(_fee);
    }

    function setSellFee(uint256 _fee) external onlyOwner {
        require(_fee <= 1000, "reHYPE: fee too high"); // 10%
        require(_fee >= 5, "reHYPE: fee too low"); // 0.05%
        sellFeeBPS = _fee;
        emit SellFeeUpdated(_fee);
    }

    function setLeverageBuyFee(uint256 _fee) external onlyOwner {
        require(_fee < buyFeeBPS, "reHYPE: leverage buy fee must be less than normal buy fee");
        require(_fee <= 1000, "reHYPE: fee too high"); // 10%
        require(_fee >= 5, "reHYPE: fee too low"); // 0.05%
        buyLeverageFeeBPS = _fee;
        emit LeverageBuyFeeUpdated(_fee);
    }

    function setFlashCloseFee(uint256 _fee) external onlyOwner {
        require(_fee <= 1000, "reHYPE: fee too high"); // 10%
        require(_fee >= 5, "reHYPE: fee too low"); // 0.05%
        flashCloseFeeBPS = _fee;
        emit FlashCloseFeeUpdated(_fee);
    }

    function setInterestManager(address _manager) external onlyOwner {
        require(_manager != address(0), "reHYPE: invalid address");
        interestManager = IInterestManager(_manager);
        emit InterestManagerUpdated(_manager);
    }

    function setProtocolFeeShare(uint256 _feeShare) external onlyOwner {
        require(_feeShare <= 7000, "reHYPE: fee share too high"); // 70%
        require(_feeShare >= 100, "reHYPE: fee share too low"); // 1%
        protocolFeeShare = _feeShare;
        emit ProtocolFeeShareUpdated(_feeShare);
    }

    function setTreasuryAddress(address _address) external onlyOwner {
        require(_address != address(0), "reHYPE: invalid address");
        treasury = _address;
        emit TreasuryUpdated(_address);
    }

    function setMasterMinter(address _minter) external onlyOwner {
        masterMinter = _minter;
        emit MasterMinterUpdated(_minter);
    }

    function setMaxMintable(uint256 _max) external onlyOwner {
        require(_max > totalSupply(), "reHYPE: max supply must be greater than total supply");
        require(_max >= maxMintable, "reHYPE: max supply can only be increased");

        maxMintable = _max;
        emit MaxMintableUpdated(maxMintable);
    }

    // Protocol Invariant
    function _upOnly(uint256 amount) private {
        uint256 newPrice = AssetToBackingFloor(1 ether);
        uint256 _totalCollateral = balanceOf(address(this));
        require(_totalCollateral >= totalCollateral, "reHYPE: collateral decreased");
        require(newPrice >= lastPrice, "reHYPE: price decreased");
        lastPrice = newPrice;
        emit PricePulse(block.timestamp, newPrice, amount);
    }

    modifier loanTenureInRange(uint256 numberOfDays) {
        require(numberOfDays < 366, "reHYPE: max borrow/extension must be 365 days or less");
        _;
    }
}
