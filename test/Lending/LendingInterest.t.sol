// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReliqHYPE} from "../../src/ReliqHYPE.sol";
import {InterestManager} from "../../src/InterestManager.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Backing Token", "MBK") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract LendingInterestIntegrationTest is Test {
    ReliqHYPE rHYPE;
    InterestManager mgr;
    MockERC20 backing;

    address owner = address(this);
    address treasury = makeAddr("treasury");
    address u1 = makeAddr("u1");

    function setUp() public {
        backing = new MockERC20();
        rHYPE = new ReliqHYPE(IERC20(address(backing)));

        mgr = new InterestManager(500); // 5%
        rHYPE.setTreasuryAddress(treasury);

        // Fund users
        backing.mint(owner, 1_000_000 ether);
        backing.mint(u1, 1_000_000 ether);

        backing.approve(address(rHYPE), type(uint256).max);
        rHYPE.setStart(1000 ether, 100 ether);
        rHYPE.setMaxMintable(1_000_000 ether);
        rHYPE.setInterestManager(address(mgr));

        // Give u1 asset collateral (owner transfers relHYPE)
        uint256 ownerBal = rHYPE.balanceOf(owner);
        vm.prank(owner);
        rHYPE.transfer(u1, ownerBal / 2);

        // Approvals
        vm.startPrank(u1);
        backing.approve(address(rHYPE), type(uint256).max);
        rHYPE.approve(address(rHYPE), type(uint256).max);
        vm.stopPrank();
    }

    function _expectedInterest(uint256 principal, uint256 daysCount) internal pure returns (uint256) {
        // 5% base, 10000 fee base, 365-day year
        return (principal * 500 * daysCount) / (10000 * 365);
    }

    function testBorrowUsesInterestManagerRate() public {
        uint256 amount = 100 ether;
        uint256 daysCount = 30;

        uint256 preTreasury = backing.balanceOf(treasury);
        uint256 preUserBacking = backing.balanceOf(u1);
        uint256 expectedCollateral = rHYPE.BackingToAssetCeil(amount);

        vm.prank(u1);
        rHYPE.borrow(amount, daysCount);

        uint256 interestFee = _expectedInterest(amount, daysCount);
        uint256 protocolFee = (interestFee * rHYPE.protocolFeeShare()) / rHYPE.FEE_BASE_BPS();
        uint256 effectiveBorrow = (amount * rHYPE.LTV_BPS()) / rHYPE.FEE_BASE_BPS();
        uint256 borrowPostFee = effectiveBorrow - interestFee;

        assertApproxEqAbs(backing.balanceOf(treasury) - preTreasury, protocolFee, 1 wei);
        assertApproxEqAbs(backing.balanceOf(u1) - preUserBacking, borrowPostFee, 1 wei);
        (uint256 collateral,,) = rHYPE.getLoanByAddress(u1);
        assertEq(collateral, expectedCollateral);
    }

    function testExtendLoanUsesInterestManagerRate() public {
        vm.prank(u1);
        rHYPE.borrow(100 ether, 30);

        uint256 preTreasury = backing.balanceOf(treasury);
        vm.prank(u1);
        uint256 fee = rHYPE.extendLoan(10);

        uint256 effectiveBorrow = (100 ether * rHYPE.LTV_BPS()) / rHYPE.FEE_BASE_BPS();
        uint256 expected = _expectedInterest(effectiveBorrow, 10);
        assertApproxEqAbs(fee, expected, 1 wei);
        uint256 protocolFee = (expected * rHYPE.protocolFeeShare()) / rHYPE.FEE_BASE_BPS();
        assertApproxEqAbs(backing.balanceOf(treasury) - preTreasury, protocolFee, 1 wei);
    }

    function testBorrowMoreUsesInterestManagerRate() public {
        vm.prank(u1);
        rHYPE.borrow(100 ether, 30);

        // Advance time by 10 days; remaining tenure used in borrowMore
        vm.warp(block.timestamp + 10 days);

        uint256 preTreasury = backing.balanceOf(treasury);
        vm.prank(u1);
        rHYPE.borrowMore(50 ether);

        // remaining tenure = oldEndDate - nextMidnight
        uint256 nextMidnight = rHYPE.getMidnightTimestamp(block.timestamp);
        (,, uint256 endDate) = rHYPE.getLoanByAddress(u1);
        uint256 remainingDays = (endDate - nextMidnight) / 1 days;

        uint256 interestFee = _expectedInterest(50 ether, remainingDays);
        uint256 protocolFee = (interestFee * rHYPE.protocolFeeShare()) / rHYPE.FEE_BASE_BPS();
        assertApproxEqAbs(backing.balanceOf(treasury) - preTreasury, protocolFee, 2 wei);
    }
}
