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

contract LiquidationTest is Test {
    ReliqHYPE reHYPE;
    InterestManager mgr;
    MockERC20 backing;

    address owner = address(this);
    address treasury = makeAddr("treasury");
    address u1 = makeAddr("u1");
    address u2 = makeAddr("u2");
    address u3 = makeAddr("u3");
    address u4 = makeAddr("u4");

    address[] users = [u1, u2, u3, u4];

    function setUp() public {
        vm.warp(1765255628);

        backing = new MockERC20();
        reHYPE = new ReliqHYPE(IERC20(address(backing)));

        mgr = new InterestManager(500); // 5%
        reHYPE.setTreasuryAddress(treasury);
        reHYPE.setInterestManager(address(mgr));

        backing.mint(owner, 100_000 ether);
        backing.approve(address(reHYPE), type(uint256).max);

        reHYPE.setStart(10_000 ether, 100 ether);
        reHYPE.setMaxMintable(type(uint256).max);

        backing.mint(u1, 100_000 ether);

        for (uint256 i; i < users.length;) {
            backing.mint(users[i], 100_000 ether);
            vm.startPrank(users[i]);
            backing.approve(address(reHYPE), type(uint256).max);
            reHYPE.buy(users[i], 100_000 ether);
            vm.stopPrank();
            unchecked {
                ++i;
            }
        }

        console.log("Last liquidation date:", reHYPE.lastLiquidationDate());
    }

    function test_LiquidationBasic() public {
        uint256 borrowAmount = 100 ether;
        uint256 tenure = 1;
        vm.prank(users[0]);
        reHYPE.borrow(borrowAmount, tenure);

        (,, uint256 endDate,) = reHYPE.Loans(users[0]);
        console.log("endDate: %s", endDate);

        vm.warp(endDate + 1);
        uint256 collateralOnDayPre = reHYPE.CollateralByDate(endDate);
        uint256 borrowedOnDayPre = reHYPE.BorrowedByDate(endDate);
        uint256 totalCollateralPre = reHYPE.totalCollateral();
        uint256 totalBorrowedPre = reHYPE.totalBorrowed();

        console.log("Warped to: %s", endDate + 1);
        console.log("Last liquidation date pre: %s", reHYPE.lastLiquidationDate());

        uint256 pricePre = reHYPE.AssetToBackingFloor(1 ether);

        reHYPE.liquidate();

        uint256 pricePost = reHYPE.AssetToBackingFloor(1 ether);

        uint256 collateralOnDayPost = reHYPE.CollateralByDate(endDate);
        uint256 borrowedOnDayPost = reHYPE.BorrowedByDate(endDate);
        uint256 totalCollateralPost = reHYPE.totalCollateral();
        uint256 totalBorrowedPost = reHYPE.totalBorrowed();

        console.log("Last liquidation date post: %s", reHYPE.lastLiquidationDate());
        // console.log("Price pre: %s, post: %s", pricePre, pricePost);

        // day-wise books don't get cleared for historical purposes
        assertEq(collateralOnDayPost, collateralOnDayPre);
        assertEq(borrowedOnDayPost, borrowedOnDayPre);

        assertEq(totalCollateralPost, totalCollateralPre - collateralOnDayPre);
        assertEq(totalBorrowedPost, totalBorrowedPre - borrowedOnDayPre);

        // liquidations must increase the price
        assertGt(pricePost, pricePre);
    }

    function test_LiquidationComplex() public {
        uint256 borrowAmount;
        uint256 tenure;

        for (uint256 i; i < users.length;) {
            borrowAmount = vm.randomUint(1 ether, 10_000 ether);
            tenure = vm.randomUint(1, 7);
            console.log("borrowAmount: %s, tenure: %s", borrowAmount, tenure);

            vm.prank(users[i]);
            reHYPE.borrow(borrowAmount, tenure);

            unchecked {
                ++i;
            }
        }

        vm.warp(block.timestamp + 8 days);

        uint256 totalCollateralPre = reHYPE.totalCollateral();
        uint256 totalBorrowedPre = reHYPE.totalBorrowed();

        uint256 startDate = reHYPE.lastLiquidationDate();
        uint256 endDateToProcess = reHYPE.getMidnightTimestamp(block.timestamp) - 1 days;
        uint256 sumCollateral;
        uint256 sumBorrowed;
        for (uint256 d = startDate; d <= endDateToProcess;) {
            sumCollateral += reHYPE.CollateralByDate(d);
            sumBorrowed += reHYPE.BorrowedByDate(d);
            unchecked {
                d += 1 days;
            }
        }

        uint256 pricePre = reHYPE.AssetToBackingFloor(1 ether);
        reHYPE.liquidate();
        uint256 pricePost = reHYPE.AssetToBackingFloor(1 ether);

        uint256 totalCollateralPost = reHYPE.totalCollateral();
        uint256 totalBorrowedPost = reHYPE.totalBorrowed();

        assertEq(totalCollateralPost, totalCollateralPre - sumCollateral);
        assertEq(totalBorrowedPost, totalBorrowedPre - sumBorrowed);
        assertGt(pricePost, pricePre);

        // Checks the loans have been cleaned up.
        for (uint256 k; k < users.length;) {
            assertTrue(reHYPE.isLoanExpired(users[k]));
            (uint256 c, uint256 b, uint256 e) = reHYPE.getLoanByAddress(users[k]);
            assertEq(c, 0);
            assertEq(b, 0);
            assertEq(e, 0);
            unchecked {
                ++k;
            }
        }

        uint256 totalCollateralAfterFirst = reHYPE.totalCollateral();
        uint256 totalBorrowedAfterFirst = reHYPE.totalBorrowed();
        reHYPE.liquidate();
        assertEq(reHYPE.totalCollateral(), totalCollateralAfterFirst);
        assertEq(reHYPE.totalBorrowed(), totalBorrowedAfterFirst);
    }
}
