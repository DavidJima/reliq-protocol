pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {ReliqHYPE} from "../../src/ReliqHYPE.sol";
import {InterestManager} from "../../src/InterestManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Backing Token", "MBK") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract LoanTest is Test {
    ReliqHYPE reHYPE;
    InterestManager mgr;
    MockERC20 backing;

    address owner = address(this);
    address treasury = makeAddr("treasury");
    address u1 = makeAddr("u1");

    function setUp() public {
        backing = new MockERC20();
        reHYPE = new ReliqHYPE(IERC20(address(backing)));

        mgr = new InterestManager(500); // 5%
        reHYPE.setTreasuryAddress(treasury);

        backing.mint(owner, 1_000_000 ether);
        backing.approve(address(reHYPE), type(uint256).max);

        vm.startPrank(u1);
        backing.approve(address(reHYPE), type(uint256).max);
        backing.mint(u1, 1_000_000 ether);
        vm.stopPrank();

        reHYPE.setStart(10_000 ether, 100 ether);
        reHYPE.setMaxMintable(1_000_000 ether);
        reHYPE.setInterestManager(address(mgr));

        // fund the contract with backing liquidity
        reHYPE.buy(owner, 100_000 ether);

        vm.startPrank(u1);
        // reHYPE.approve(address(reHYPE), type(uint256).max);
        reHYPE.buy(u1, 10_000 ether); // acquire reHYPE for u1
        vm.stopPrank();
    }

    function test_BorrowBasic() public {
        uint256 amountToBorrow = 1_001 ether;
        uint256 tenure = 365;

        vm.prank(u1);
        reHYPE.borrow(amountToBorrow, tenure);

        (uint256 collateral, uint256 borrowed,, uint256 loanTenure) = reHYPE.Loans(u1);

        assertGt(reHYPE.AssetToBackingFloor(collateral) * 99 / 100, borrowed);
        assertEq(borrowed, amountToBorrow * 99 / 100); // loan is recored sans fees
        assertEq(loanTenure, tenure);

        // console.log("Collateral posted:", collateral);
        // console.log("Collateral (in backing):", reHYPE.AssetToBackingFloor(collateral));
        // console.log("Amount borrowed:", borrowed);
    }

    function test_BorrowFeeCollection() public {
        uint256 amountToBorrow = 1_000 ether;
        uint256 tenure = 365;

        uint256 treasuryBalPreOp = backing.balanceOf(treasury);
        uint256 u1BalPreOp = backing.balanceOf(u1);

        uint256 expectedFee = (amountToBorrow * 500 / 10_000); // 5% fee
        uint256 protocolFee = expectedFee * reHYPE.protocolFeeShare() / 10_000;

        vm.prank(u1);
        reHYPE.borrow(amountToBorrow, tenure);

        uint256 treasuryBalPostOp = backing.balanceOf(treasury);
        uint256 u1BalPostOp = backing.balanceOf(u1);

        uint256 treasuryFeeReceived = treasuryBalPostOp - treasuryBalPreOp;
        uint256 u1BalDiff = u1BalPostOp - u1BalPreOp;

        assertEq(treasuryFeeReceived, protocolFee);
        assertEq(u1BalDiff, (amountToBorrow * 99) / 100 - expectedFee);

        // console.log("Treasury fee received:", treasuryFeeReceived);
        // console.log("u1 balance difference:", u1BalDiff);
    }

    struct BalanceState {
        uint256 u1Asset;
        uint256 u1Backing;
        uint256 reHYPEAsset;
        uint256 reHYPEBacking;
    }

    function test_BorrowStateUpdates() public {
        uint256 amountToBorrow = 1_000 ether;
        uint256 tenure = 365;

        BalanceState memory preOp;
        BalanceState memory postOp;

        preOp.u1Asset = reHYPE.balanceOf(u1);
        preOp.u1Backing = backing.balanceOf(u1);
        preOp.reHYPEAsset = reHYPE.balanceOf(address(reHYPE));
        preOp.reHYPEBacking = backing.balanceOf(address(reHYPE));

        vm.prank(u1);
        reHYPE.borrow(amountToBorrow, tenure);

        (uint256 collateral, uint256 borrowed, uint256 endDate,) = reHYPE.Loans(u1);

        uint256 totalBorrowed = reHYPE.totalBorrowed();
        uint256 totalCollateral = reHYPE.totalCollateral();
        uint256 collateralAtEndDate = reHYPE.CollateralByDate(endDate);
        uint256 borrowedAtEndDate = reHYPE.BorrowedByDate(endDate);

        // console.log("Collateral posted:", collateral);
        // console.log("Borrowed amount:", borrowed);
        // console.log("Loan end date (timestamp):", endDate);
        // console.log("Loan tenure (days):", loanTenure);

        postOp.u1Asset = reHYPE.balanceOf(u1);
        postOp.u1Backing = backing.balanceOf(u1);
        postOp.reHYPEAsset = reHYPE.balanceOf(address(reHYPE));
        postOp.reHYPEBacking = backing.balanceOf(address(reHYPE));

        uint256 interestFee = reHYPE.getInterestFee(amountToBorrow, tenure);
        uint256 treasuryShare = interestFee * reHYPE.protocolFeeShare() / 10_000;

        assertEq(preOp.u1Asset - collateral, postOp.u1Asset);
        assertEq(postOp.u1Backing, preOp.u1Backing + borrowed - interestFee);
        assertEq(preOp.reHYPEAsset + collateral, postOp.reHYPEAsset);
        assertEq(preOp.reHYPEBacking - (borrowed - interestFee) - treasuryShare, postOp.reHYPEBacking);

        assertEq(borrowed, totalBorrowed);
        assertEq(collateral, totalCollateral);
        assertEq(collateral, collateralAtEndDate);
        assertEq(borrowed, borrowedAtEndDate);
    }

    function test_BorrowOneActiveLoan() public {
        uint256 amountToBorrow = 1_000 ether;
        uint256 tenure = 365;

        vm.prank(u1);
        reHYPE.borrow(amountToBorrow, tenure);

        vm.prank(u1);
        vm.expectRevert();
        reHYPE.borrow(amountToBorrow, tenure);
    }

    function test_OnlyBorrowValidTenure() public {
        uint256 amountToBorrow = 1_000 ether;

        vm.startPrank(u1);

        vm.expectRevert();
        reHYPE.borrow(amountToBorrow, 0);

        vm.expectRevert();
        reHYPE.borrow(amountToBorrow, 366);

        vm.expectRevert();
        reHYPE.borrow(amountToBorrow, 10000);

        reHYPE.borrow(amountToBorrow, 300);

        vm.stopPrank();
    }

    function test_OnlyBorrowValidAmount() public {
        uint256 tenure = 365;

        vm.startPrank(u1);

        vm.expectRevert();
        reHYPE.borrow(0, tenure);

        uint256 maxAvailableInContract = backing.balanceOf(address(reHYPE));
        uint256 maxBorrowableForU1 = reHYPE.AssetToBackingFloor(reHYPE.balanceOf(u1));

        vm.expectRevert();
        reHYPE.borrow(maxAvailableInContract + 1, tenure);

        vm.expectRevert();
        reHYPE.borrow(maxBorrowableForU1 + 1, tenure);

        reHYPE.borrow(1_000 ether, tenure);

        vm.stopPrank();
    }

    function test_BorrowLoanByDateAgg() public {
        uint256 amountToBorrow = 1_000 ether;
        uint256 tenure = 365;

        vm.prank(owner);
        reHYPE.borrow(amountToBorrow, tenure);

        vm.prank(u1);
        reHYPE.borrow(amountToBorrow, tenure);

        (uint256 collateralU1, uint256 borrowedU1, uint256 endDateU1,) = reHYPE.Loans(u1);
        (uint256 collateralOwner, uint256 borrowedOwner, uint256 endDateOwner,) = reHYPE.Loans(owner);

        assertEq(endDateU1, endDateOwner);

        uint256 borrowedAtEndDate = reHYPE.BorrowedByDate(endDateU1);
        uint256 collateralAtEndDate = reHYPE.CollateralByDate(endDateU1);

        assertEq(borrowedAtEndDate, borrowedU1 + borrowedOwner);
        assertEq(collateralAtEndDate, collateralU1 + collateralOwner);
    }

    function test_ExpiredLoanCleanUpOnBorrow() public {
        uint256 amountToBorrow = 1_000 ether;
        uint256 tenure = 1; // 1 day

        vm.prank(u1);
        reHYPE.borrow(amountToBorrow, tenure);

        (uint256 collateral, uint256 borrowed,,) = reHYPE.Loans(u1);
        assertGt(collateral, 0);
        assertGt(borrowed, 0);

        // fast forward time by 2 days
        vm.warp(block.timestamp + 2 days);

        uint256 newBorrowAmount = 100 ether;
        uint256 newTenure = 30;
        vm.prank(u1);
        reHYPE.borrow(newBorrowAmount, newTenure); // new borrow after tenure close should trigger cleanup

        (uint256 collateralAfter, uint256 borrowedAfter,, uint256 tenureAfter) = reHYPE.Loans(u1);
        // console.log("Collateral after:", collateralAfter);
        // console.log("Borrowed after:", borrowedAfter);
        // console.log("Tenure after:", tenureAfter);

        assertGt(collateralAfter, reHYPE.BackingToAssetCeil(newBorrowAmount));
        assertEq(borrowedAfter, ((newBorrowAmount * 99) / 100));
        assertEq(tenureAfter, newTenure);
    }

    function test_ClosePositionBasic() public {
        uint256 amountToBorrow = 1_000 ether;
        uint256 tenure = 365;

        vm.prank(u1);
        reHYPE.borrow(amountToBorrow, tenure);

        (uint256 collateral, uint256 borrowed, uint256 endDate,) = reHYPE.Loans(u1);

        assertGt(collateral, 0);
        assertGt(borrowed, 0);

        uint256 collateralByDatePreOp = reHYPE.CollateralByDate(endDate);
        uint256 borrowedByDatePreOp = reHYPE.BorrowedByDate(endDate);

        BalanceState memory preOp;
        BalanceState memory postOp;

        preOp.u1Asset = reHYPE.balanceOf(u1);
        preOp.u1Backing = backing.balanceOf(u1);
        preOp.reHYPEAsset = reHYPE.balanceOf(address(reHYPE));
        preOp.reHYPEBacking = backing.balanceOf(address(reHYPE));

        vm.prank(u1);
        reHYPE.closePosition();

        (uint256 collateralAfter, uint256 borrowedAfter,,) = reHYPE.Loans(u1);

        uint256 collateralByDatePostOp = reHYPE.CollateralByDate(endDate);
        uint256 borrowedByDatePostOp = reHYPE.BorrowedByDate(endDate);

        postOp.u1Asset = reHYPE.balanceOf(u1);
        postOp.u1Backing = backing.balanceOf(u1);
        postOp.reHYPEAsset = reHYPE.balanceOf(address(reHYPE));
        postOp.reHYPEBacking = backing.balanceOf(address(reHYPE));

        assertEq(collateralAfter, 0);
        assertEq(borrowedAfter, 0);

        assertEq(collateralByDatePreOp - collateral, collateralByDatePostOp);
        assertEq(borrowedByDatePreOp - borrowed, borrowedByDatePostOp);

        assertEq(postOp.u1Asset - collateral, preOp.u1Asset);
        assertEq(postOp.u1Backing + borrowed, preOp.u1Backing);
        assertEq(preOp.reHYPEAsset - collateral, postOp.reHYPEAsset);
        assertEq(preOp.reHYPEBacking + borrowed, postOp.reHYPEBacking);
    }

    function test_ClosePositionAfterExpiry() public {
        uint256 amountToBorrow = 1_000 ether;
        uint256 tenure = 1; // 1 day

        vm.prank(u1);
        reHYPE.borrow(amountToBorrow, tenure);

        (uint256 collateral, uint256 borrowed, uint256 endDate,) = reHYPE.Loans(u1);

        assertGt(collateral, 0);
        assertGt(borrowed, 0);

        // fast forward time after endDate
        vm.warp(endDate + 1 days);

        vm.prank(u1);
        vm.expectRevert();
        reHYPE.closePosition(); // should revert as loan is expired
    }

    function test_PartialRepay() public {
        uint256 amountToBorrow = 1_000 ether;
        uint256 tenure = 365;

        vm.prank(u1);
        reHYPE.borrow(amountToBorrow, tenure);

        (, uint256 borrowedPre, uint256 endDate,) = reHYPE.Loans(u1);
        uint256 borrowedByDatePre = reHYPE.BorrowedByDate(endDate);

        uint256 u1BackingBalPre = backing.balanceOf(u1);
        uint256 reHYPEBackingBalPre = backing.balanceOf(address(reHYPE));

        uint256 repayAmount = amountToBorrow / 2;
        vm.prank(u1);
        reHYPE.repay(repayAmount);

        uint256 u1BackingBalPost = backing.balanceOf(u1);
        uint256 reHYPEBackingBalPost = backing.balanceOf(address(reHYPE));

        (, uint256 borrowedPost,,) = reHYPE.Loans(u1);
        uint256 borrowedByDatePost = reHYPE.BorrowedByDate(endDate);

        assertEq(borrowedPost, borrowedPre - repayAmount);
        assertEq(borrowedByDatePre - repayAmount, borrowedByDatePost);
        assertEq(u1BackingBalPre - repayAmount, u1BackingBalPost);
        assertEq(reHYPEBackingBalPre + repayAmount, reHYPEBackingBalPost);
    }

    function test_PartialRepayInvalid() public {
        uint256 amountToBorrow = 1_000 ether;
        uint256 tenure = 365;

        vm.prank(u1);
        reHYPE.borrow(amountToBorrow, tenure);

        (, uint256 borrowedPre, uint256 endDate,) = reHYPE.Loans(u1);

        vm.startPrank(u1);

        vm.expectRevert();
        reHYPE.repay(0); // zero repay

        vm.expectRevert();
        reHYPE.repay(borrowedPre); // over repay

        vm.warp(endDate + 1);

        vm.expectRevert();
        reHYPE.repay(100 ether); // repay after expiry

        vm.stopPrank();
    }

    function test_RemoveCollateral() public {
        uint256 amountToBorrow = 1_000 ether;
        uint256 tenure = 365;

        vm.startPrank(u1);
        reHYPE.borrow(amountToBorrow, tenure);
        reHYPE.repay(200 ether);
        vm.stopPrank();

        (uint256 collateralPre, uint256 borrowedPre, uint256 endDate,) = reHYPE.Loans(u1);
        uint256 collateralByDatePre = reHYPE.CollateralByDate(endDate);

        uint256 u1AssetBalPre = reHYPE.balanceOf(u1);
        uint256 reHYPEAssetBalPre = reHYPE.balanceOf(address(reHYPE));

        uint256 safeCollateralToRemove =
            reHYPE.BackingToAssetFloor(((reHYPE.AssetToBackingFloor(collateralPre) * 9900 / 10_000) - borrowedPre));

        // console.log("Collateral pre:", collateralPre);
        // console.log("Borrowed pre:", borrowedPre);
        // console.log("Price pre", reHYPE.AssetToBackingFloor(1 ether));
        // console.log("Safe collateral to remove:", safeCollateralToRemove);
        vm.prank(u1);
        reHYPE.removeCollateral(safeCollateralToRemove);

        uint256 u1AssetBalPost = reHYPE.balanceOf(u1);
        uint256 reHYPEAssetBalPost = reHYPE.balanceOf(address(reHYPE));
        (uint256 collateralPost,,,) = reHYPE.Loans(u1);
        uint256 collateralByDatePost = reHYPE.CollateralByDate(endDate);

        assertEq(collateralPost, collateralPre - safeCollateralToRemove);
        assertEq(collateralByDatePre - safeCollateralToRemove, collateralByDatePost);
        assertEq(u1AssetBalPost, u1AssetBalPre + safeCollateralToRemove);
        assertEq(reHYPEAssetBalPost, reHYPEAssetBalPre - safeCollateralToRemove);
    }

    function test_RemoveCollateralInvalid() public {
        uint256 amountToBorrow = 1_000 ether;
        uint256 tenure = 365;

        vm.prank(u1);
        reHYPE.borrow(amountToBorrow, tenure);

        (uint256 collateral, uint256 borrowed, uint256 endDate,) = reHYPE.Loans(u1);

        vm.startPrank(u1);

        vm.expectRevert();
        reHYPE.removeCollateral(0); // zero remove

        uint256 unsafeCollateralToRemove = collateral - reHYPE.BackingToAssetCeil(borrowed);
        vm.expectRevert();
        reHYPE.removeCollateral(unsafeCollateralToRemove); // over remove

        vm.warp(endDate + 1);
        vm.expectRevert();
        reHYPE.removeCollateral(1 ether); // remove after expiry

        vm.stopPrank();
        // console.log(block.timestamp);
    }

    function test_ExtendLoan() public {
        vm.warp(1765221600);

        vm.prank(u1);
        reHYPE.borrow(1_000 ether, 30);

        vm.warp(block.timestamp + 10 days);

        BalanceState memory preOp;
        BalanceState memory postOp;

        (,, uint256 endDatePre,) = reHYPE.Loans(u1);
        // console.log("Loan end date pre extend:", endDatePre);
        // console.log("Loan tenure pre extend (days):", tenurePre);
        // uint256 collateralByDatePre = reHYPE.CollateralByDate(endDatePre);
        // uint256 borrowedByDatePre = reHYPE.BorrowedByDate(endDatePre);

        preOp.u1Backing = backing.balanceOf(u1);
        preOp.reHYPEBacking = backing.balanceOf(address(reHYPE));

        uint256 treasuryBalPre = backing.balanceOf(treasury);

        uint256 additionalTenure = 60;
        vm.prank(u1);
        reHYPE.extendLoan(additionalTenure);

        (uint256 collateral, uint256 borrowed, uint256 endDatePost,) = reHYPE.Loans(u1);

        postOp.u1Asset = reHYPE.balanceOf(u1);
        postOp.u1Backing = backing.balanceOf(u1);
        postOp.reHYPEAsset = reHYPE.balanceOf(address(reHYPE));
        postOp.reHYPEBacking = backing.balanceOf(address(reHYPE));

        uint256 treasuryBalPost = backing.balanceOf(treasury);

        assertEq((endDatePost - endDatePre) / 1 days, additionalTenure);

        assertEq(reHYPE.CollateralByDate(endDatePre), 0);
        assertEq(reHYPE.BorrowedByDate(endDatePre), 0);
        assertEq(reHYPE.CollateralByDate(endDatePost), collateral);
        assertEq(reHYPE.BorrowedByDate(endDatePost), borrowed);

        assertApproxEqAbs(
            postOp.reHYPEBacking,
            preOp.reHYPEBacking + ((reHYPE.getInterestFee(borrowed, additionalTenure) * 7_000) / 10_000),
            1 wei
        );
        assertEq(postOp.u1Backing, preOp.u1Backing - reHYPE.getInterestFee(borrowed, additionalTenure));
        assertEq(
            treasuryBalPost - treasuryBalPre,
            reHYPE.getInterestFee(borrowed, additionalTenure) * reHYPE.protocolFeeShare() / 10_000
        );
    }

    function test_ExtendLoanInvalid() public {
        uint256 amountToBorrow = 1_000 ether;
        uint256 tenure = 30;

        vm.prank(u1);
        reHYPE.borrow(amountToBorrow, tenure);

        vm.startPrank(u1);

        vm.expectRevert();
        reHYPE.extendLoan(0); // zero extend

        vm.expectRevert();
        reHYPE.extendLoan(366); // over extend

        // fast forward time after loan expiry
        vm.warp(block.timestamp + (tenure + 1) * 1 days);

        vm.expectRevert();
        reHYPE.extendLoan(30); // extend after expiry

        vm.stopPrank();
    }

    function test_BorrowMore() public {
        BalanceState memory preOp;
        BalanceState memory postOp;

        /*  
        ****** Scenario 1: borrowMore after a borrow ****** 
            -- At this point, u1 has an active loan of 1000 ether borrowed for 365 days
            -- No additional collateral is available on the position.
            -- u1 attempts to borrow an additional 500 ether using borrowMore
            -- The system has no extra collateral available, it'll be asked for from the user. 
        */

        vm.prank(u1);
        reHYPE.borrow(1_000 ether, 365); // first vanilla borrow

        (uint256 collateralPre, uint256 borrowedPre, uint256 endDate,) = reHYPE.Loans(u1);
        uint256 collateralByDatePre = reHYPE.CollateralByDate(endDate);
        uint256 borrowedByDatePre = reHYPE.BorrowedByDate(endDate);

        preOp.u1Backing = backing.balanceOf(u1);
        preOp.reHYPEBacking = backing.balanceOf(address(reHYPE));
        preOp.u1Asset = reHYPE.balanceOf(u1);
        preOp.reHYPEAsset = reHYPE.balanceOf(address(reHYPE));

        uint256 treasuryBalPre = backing.balanceOf(treasury);

        uint256 additionalBorrowAmount = 1000 ether;
        vm.prank(u1);
        reHYPE.borrowMore(additionalBorrowAmount); // borrow more

        (uint256 collateralPost, uint256 borrowedPost,,) = reHYPE.Loans(u1);
        uint256 collateralByDatePost = reHYPE.CollateralByDate(endDate);
        uint256 borrowedByDatePost = reHYPE.BorrowedByDate(endDate);

        postOp.u1Backing = backing.balanceOf(u1);
        postOp.reHYPEBacking = backing.balanceOf(address(reHYPE));
        postOp.u1Asset = reHYPE.balanceOf(u1);
        postOp.reHYPEAsset = reHYPE.balanceOf(address(reHYPE));

        uint256 treasuryBalPost = backing.balanceOf(treasury);

        // assert the additional collateral is pulled from the user
        assertEq(preOp.u1Asset - postOp.u1Asset, collateralPost - collateralPre);
        assertEq(postOp.reHYPEAsset - preOp.reHYPEAsset, collateralPost - collateralPre);

        // assert loan book is updated properly
        assertEq(collateralByDatePost - collateralByDatePre, collateralPost - collateralPre);
        assertEq(borrowedByDatePost - borrowedByDatePre, borrowedPost - borrowedPre);

        // assert fees is deducted and routed to the treasury
        assertEq(
            treasuryBalPost - treasuryBalPre,
            reHYPE.getInterestFee(additionalBorrowAmount, 365) * reHYPE.protocolFeeShare() / 10_000
        );
    }

    function test_BorrowMorePartialScenario() public {
        /* 
        ****** Scenario 3: borrowMore with partially free collateral ****** 
            -- At this point, u1 has an active loan ~1700 ether borrowed 
            -- The posted collateral can cover close to ~2000 ether of borrow
            -- u1 decides to borrow an additional 500 ether using borrowMore
            -- The system should utilize the free collateral first, then pull the deficit from the user.
        */

        // scenario setup
        vm.startPrank(u1);
        reHYPE.borrow(2_000 ether, 365); // first vanilla borrow
        reHYPE.repay(250 ether); // repay a portion of the loan
        uint256 additionalBorrowAmount = 500 ether;

        BalanceState memory preOp;
        BalanceState memory postOp;

        // state before borrowMore
        (uint256 collateralPre, uint256 borrowedPre, uint256 endDate,) = reHYPE.Loans(u1);
        uint256 collateralByDatePre = reHYPE.CollateralByDate(endDate);
        uint256 borrowedByDatePre = reHYPE.BorrowedByDate(endDate);

        preOp.u1Backing = backing.balanceOf(u1);
        preOp.reHYPEBacking = backing.balanceOf(address(reHYPE));
        preOp.u1Asset = reHYPE.balanceOf(u1);
        preOp.reHYPEAsset = reHYPE.balanceOf(address(reHYPE));

        uint256 collateralDeficit;
        {
            uint256 existingCollatUsed = reHYPE.BackingToAssetFloor(borrowedPre);
            uint256 excessCollateral = (collateralPre * 9900 / 10_000) - existingCollatUsed;
            uint256 collateralRequiredForNewBorrow = reHYPE.BackingToAssetCeil(additionalBorrowAmount);
            collateralDeficit = collateralRequiredForNewBorrow;
            if (excessCollateral >= collateralDeficit) {
                collateralDeficit = 0;
            } else {
                collateralDeficit -= excessCollateral;
            }
        }

        reHYPE.borrowMore(additionalBorrowAmount); // borrow more
        vm.stopPrank();

        // state after borrowMore
        (uint256 collateralPost, uint256 borrowedPost,,) = reHYPE.Loans(u1);
        uint256 collateralByDatePost = reHYPE.CollateralByDate(endDate);
        uint256 borrowedByDatePost = reHYPE.BorrowedByDate(endDate);

        postOp.u1Backing = backing.balanceOf(u1);
        postOp.reHYPEBacking = backing.balanceOf(address(reHYPE));
        postOp.u1Asset = reHYPE.balanceOf(u1);
        postOp.reHYPEAsset = reHYPE.balanceOf(address(reHYPE));

        {
            // assert the additional collateral is pulled from the user only for the deficit
            assertEq(preOp.u1Asset - postOp.u1Asset, collateralDeficit);
            assertEq(postOp.reHYPEAsset - preOp.reHYPEAsset, collateralDeficit);

            // assert loan book is updated properly
            assertEq(collateralByDatePost - collateralByDatePre, collateralPost - collateralPre);
            assertEq(borrowedByDatePost - borrowedByDatePre, borrowedPost - borrowedPre);
        }
    }

    function test_BorrowMoreInvalid() public {
        uint256 amountToBorrow = 1_000 ether;
        uint256 tenure = 365;

        vm.prank(u1);
        reHYPE.borrow(amountToBorrow, tenure);

        vm.startPrank(u1);

        vm.expectRevert();
        reHYPE.borrowMore(0); // zero borrow more

        uint256 maxAvailableInContract = backing.balanceOf(address(reHYPE));
        uint256 maxBorrowableForU1 = reHYPE.AssetToBackingFloor(reHYPE.balanceOf(u1));

        vm.expectRevert();
        reHYPE.borrowMore(maxAvailableInContract + 1); // over borrow more than contract liquidity

        vm.expectRevert();
        reHYPE.borrowMore(maxBorrowableForU1 + 1 ether); // over borrow more than max borrowable

        vm.stopPrank();
    }
}
