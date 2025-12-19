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

contract LeverageTest is Test {
    ReliqHYPE reHYPE;
    InterestManager mgr;
    MockERC20 backing;

    address owner = address(this);
    address treasury = makeAddr("treasury");
    address u1 = makeAddr("u1");
    address u2 = makeAddr("u2");
    address u3 = makeAddr("u3");

    function setUp() public {
        backing = new MockERC20();
        reHYPE = new ReliqHYPE(IERC20(address(backing)));

        mgr = new InterestManager(500); // 5%
        reHYPE.setTreasuryAddress(treasury);

        // Fund users
        backing.mint(owner, 1_000_000 ether);
        backing.mint(u1, 1_000_000 ether);
        backing.mint(u2, 1_000_000 ether);
        backing.mint(u3, 1_000_000 ether);

        backing.approve(address(reHYPE), type(uint256).max);

        reHYPE.setStart(10_000 ether, 100 ether);
        reHYPE.setMaxMintable(1_000_000 ether);
        reHYPE.setInterestManager(address(mgr));

        reHYPE.buy(owner, 100_000 ether);

        vm.startPrank(u1);
        backing.approve(address(reHYPE), type(uint256).max);
        reHYPE.buy(u1, 100 ether);
        vm.stopPrank();
    }

    function test_BasicLeverage() public {
        uint256 pricePreOp = reHYPE.AssetToBackingFloor(1 ether);

        uint256 amountIn = 1000 ether;
        uint256 tenure = 365;

        vm.startPrank(u1);
        reHYPE.leverage(amountIn, tenure);
        vm.stopPrank();

        uint256 pricePostOp = reHYPE.AssetToBackingFloor(1 ether);
        (uint256 collateral, uint256 borrowed,, uint256 tenurePostOp) = reHYPE.Loans(u1);

        assertGt(pricePostOp, pricePreOp); // price should increase post op.
        assertGt(collateral, 0); // collateral should be non-zero post op.
        assertGt(borrowed, 0); // borrowed should be non-zero post op.
        assertEq(tenurePostOp, tenure); // tenure should be as expected.
    }

    function test_LeverageLTVCalculation() public {
        uint256 amountIn = 1000 ether;
        uint256 tenure = 365;

        vm.startPrank(u1);
        reHYPE.leverage(amountIn, tenure);
        vm.stopPrank();

        uint256 price = reHYPE.AssetToBackingFloor(1 ether);
        (uint256 collateral, uint256 borrowed,,) = reHYPE.Loans(u1);

        uint256 estimatedLTV = (borrowed * 1e36) / (collateral * price);
        assertLt(estimatedLTV, 9.9e17); // LTV should be below 99%
        assertGt(estimatedLTV, 9.85e17); // LTV should be above 98.5%
    }

    function test_FeeCollectionOnLeverage() public {
        uint256 amountIn = 1000 ether;
        uint256 tenure = 365;

        uint256 expectedLeverageBuyFee = (amountIn * reHYPE.buyLeverageFeeBPS()) / reHYPE.FEE_BASE_BPS();
        uint256 expectedInterestCharged = (amountIn * mgr.getInterestRateBPS(u1)) / reHYPE.FEE_BASE_BPS();

        uint256 expectedFeeToTreasury =
            ((expectedInterestCharged + expectedLeverageBuyFee) * reHYPE.protocolFeeShare()) / reHYPE.FEE_BASE_BPS();

        uint256 treasuryBalPreOp = backing.balanceOf(treasury);

        vm.startPrank(u1);
        reHYPE.leverage(amountIn, tenure);
        vm.stopPrank();

        uint256 treasuryBalPostOp = backing.balanceOf(treasury);
        assertApproxEqAbs(treasuryBalPostOp - treasuryBalPreOp, expectedFeeToTreasury, 1 wei); // treasury should receive expected fees.
    }

    function test_LeverageMultiplier() public {
        uint256 amountIn = 1000 ether;
        uint256 tenure = 365;

        uint256 u1BackingBalPreOp = backing.balanceOf(u1);

        vm.startPrank(u1);
        reHYPE.leverage(amountIn, tenure);
        vm.stopPrank();

        uint256 u1BackingBalPostOp = backing.balanceOf(u1);
        (uint256 collateral,,,) = reHYPE.Loans(u1);

        uint256 totalSpent = u1BackingBalPreOp - u1BackingBalPostOp;
        uint256 exposure = (collateral * reHYPE.AssetToBackingFloor(1 ether)) / 1e18;
        uint256 multiplier = (exposure) / totalSpent;

        assertGt(multiplier, 10);

        // console.log("Total Spent:", totalSpent);
        // console.log("Exposure:", exposure);
        // console.log("Leverage Multiplier (x100):", (exposure) / totalSpent);
    }

    function test_FlashClosePosition() public {
        uint256 amountIn = 1000 ether;
        uint256 tenure = 30;

        // uint256 u1BackingBalPreLeverage = backing.balanceOf(u1);

        vm.startPrank(u1);
        reHYPE.leverage(amountIn, tenure);
        vm.stopPrank();

        // (uint256 collateralPreOp, uint256 borrowedPreOp,,) = reHYPE.Loans(u1);

        // console.log("Collateral before flash close (wei):", collateralPreOp);
        // console.log(
        //     "Collateral priced as borrow before flash close (wei):", reHYPE.AssetToBackingFloor(collateralPreOp)
        // );
        // console.log("Borrowed before flash close (wei):", borrowedPreOp);

        uint256 u1BackingBalPreOp = backing.balanceOf(u1);
        uint256 treasuryBalPreOp = backing.balanceOf(treasury);

        vm.startPrank(u1);
        reHYPE.flashClosePosition();
        vm.stopPrank();

        uint256 u1BackingBalPostOp = backing.balanceOf(u1);
        uint256 treasuryBalPostOp = backing.balanceOf(treasury);
        (uint256 collateralPostOp, uint256 borrowedPostOp,, uint256 tenurePostOp) = reHYPE.Loans(u1);

        assertEq(collateralPostOp, 0);
        assertEq(borrowedPostOp, 0);
        assertEq(tenurePostOp, 0);
        assertGt(u1BackingBalPostOp, u1BackingBalPreOp); // user should have more backing post op.
        assertGt(treasuryBalPostOp, treasuryBalPreOp); // treasury should have more backing post op.

        // console.log("Profit from flash close (wei):", u1BackingBalPostOp - u1BackingBalPreOp);
        // console.log("Balance diff after lev and flash close (wei):", u1BackingBalPreLeverage - u1BackingBalPostOp);
        // console.log("Fees to treasury from flash close (wei):", treasuryBalPostOp - treasuryBalPreOp);
    }
}
