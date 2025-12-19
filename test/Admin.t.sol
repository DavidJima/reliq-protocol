// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/ReliqHYPE.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Backing Token", "MOCK") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract AdminFunctionTest is Test {
    ReliqHYPE public rHYPE;
    MockERC20 public backing;

    address owner = address(this);
    address treasury = address(0xFEE);

    function setUp() public {
        vm.label(owner, "Owner");
        vm.label(treasury, "Treasury");

        backing = new MockERC20();
        rHYPE = new ReliqHYPE(IERC20(address(backing)));
    }

    function testSetupParameters() public {
        assertEq(rHYPE.buyFeeBPS(), 300, "buy feebps"); // 3% fee
        assertEq(rHYPE.sellFeeBPS(), 300, "sell feebps"); // 3% fee
        assertEq(rHYPE.buyLeverageFeeBPS(), 100, "buy leverage feebps"); // 1% fee
        assertEq(rHYPE.flashCloseFeeBPS(), 100, "flash close feebps"); // 1% fee
        assertEq(rHYPE.protocolFeeShare(), 3000, "protocol fee share"); // 30% treasury share
        assertEq(rHYPE.FEE_BASE_BPS(), 10000, "fee basebps"); // 10,000 bps
    }

    function testUpdateFeeBPS() public {
        // Test buyFeeBPS update
        vm.prank(owner);
        rHYPE.setBuyFee(500);
        assertEq(rHYPE.buyFeeBPS(), 500, "buy fee"); // 5% fee

        // Test sellFeeBPS update
        vm.prank(owner);
        rHYPE.setSellFee(400);
        assertEq(rHYPE.sellFeeBPS(), 400, "sell fee"); // 4% fee

        // Test buyLeverageFeeBPS update
        vm.prank(owner);
        rHYPE.setLeverageBuyFee(50);
        assertEq(rHYPE.buyLeverageFeeBPS(), 50, "buy leverage fee"); // 0.5% fee

        // Test flashCloseFeeBPS update
        vm.prank(owner);
        rHYPE.setFlashCloseFee(200);
        assertEq(rHYPE.flashCloseFeeBPS(), 200, "flash close fee"); // 2% fee

        // Test protocolFeeShare update
        vm.prank(owner);
        rHYPE.setProtocolFeeShare(2000);
        assertEq(rHYPE.protocolFeeShare(), 2000, "protocol fee share"); // 20% treasury share

        // Interest rate managed externally via InterestManager
    }

    function testBuyFeeBoundaries() public {
        // Test buyFeeBPS boundaries (5-1000)
        vm.startPrank(owner);

        // Test lower bound
        vm.expectRevert("reHYPE: fee too low");
        rHYPE.setBuyFee(4);

        rHYPE.setBuyFee(5); // Should succeed at minimum

        // Test upper bound
        vm.expectRevert("reHYPE: fee too high");
        rHYPE.setBuyFee(1001);

        rHYPE.setBuyFee(1000); // Should succeed at maximum
        vm.stopPrank();
    }

    function testSellFeeBoundaries() public {
        vm.startPrank(owner);

        // Test upper bound only (contract doesn't have lower bound check)
        vm.expectRevert("reHYPE: fee too high");
        rHYPE.setSellFee(1001);

        rHYPE.setSellFee(1000); // Should succeed at maximum
        vm.stopPrank();
    }

    function testLeverageBuyFeeBoundaries() public {
        vm.startPrank(owner);

        // Set buyFee to test the "less than" requirement
        rHYPE.setBuyFee(500);

        // Test lower bound
        vm.expectRevert("reHYPE: fee too low");
        rHYPE.setLeverageBuyFee(4);

        rHYPE.setLeverageBuyFee(5); // Should succeed at minimum

        // Test upper bound
        vm.expectRevert();
        rHYPE.setLeverageBuyFee(1001);

        // Test must be less than buyFeeBPS
        vm.expectRevert("reHYPE: leverage buy fee must be less than normal buy fee");
        rHYPE.setLeverageBuyFee(500); // Equal to buyFeeBPS

        rHYPE.setLeverageBuyFee(499); // Should succeed just below buyFeeBPS
        vm.stopPrank();
    }

    function testFlashCloseFeeBoundaries() public {
        vm.startPrank(owner);

        // Test lower bound
        vm.expectRevert("reHYPE: fee too low");
        rHYPE.setFlashCloseFee(4);

        rHYPE.setFlashCloseFee(5); // Should succeed at minimum

        // Test upper bound
        vm.expectRevert("reHYPE: fee too high");
        rHYPE.setFlashCloseFee(1001);

        rHYPE.setFlashCloseFee(1000); // Should succeed at maximum
        vm.stopPrank();
    }

    // Interest rate boundaries are enforced in InterestManager

    function testProtocolFeeShareBoundaries() public {
        vm.startPrank(owner);

        // Test lower bound
        vm.expectRevert("reHYPE: fee share too low");
        rHYPE.setProtocolFeeShare(99);

        rHYPE.setProtocolFeeShare(100); // Should succeed at minimum

        // Test upper bound
        vm.expectRevert("reHYPE: fee share too high");
        rHYPE.setProtocolFeeShare(7001);

        rHYPE.setProtocolFeeShare(7000); // Should succeed at maximum
        vm.stopPrank();
    }

    function testUpdateFeeBPSNotOwner() public {
        vm.prank(address(0x123));
        vm.expectRevert();
        rHYPE.setBuyFee(500);

        // Test sellFee update
        vm.prank(address(0x123));
        vm.expectRevert();
        rHYPE.setSellFee(400);

        // Test buyLeverageFee update
        vm.prank(address(0x123));
        vm.expectRevert();
        rHYPE.setLeverageBuyFee(50);

        // Test flashCloseFee update
        vm.prank(address(0x123));
        vm.expectRevert();
        rHYPE.setFlashCloseFee(200);

        // Test protocolFeeShare update
        vm.prank(address(0x123));
        vm.expectRevert();
        rHYPE.setProtocolFeeShare(2000);

        // InterestManager controls rates; ReliqHYPE has no direct setter
    }

    function testUpdateTreasury() public {
        vm.prank(address(0x123));
        vm.expectRevert();
        rHYPE.setTreasuryAddress(treasury);

        vm.prank(owner);
        rHYPE.setTreasuryAddress(treasury);
        assertEq(rHYPE.treasury(), treasury, "treasury");

        vm.expectRevert();
        rHYPE.setTreasuryAddress(address(0));
    }

    function testUpdateMasterMinter() public {
        vm.prank(address(0x123));
        vm.expectRevert();
        rHYPE.setMasterMinter(address(0x456));

        vm.prank(owner);
        rHYPE.setMasterMinter(address(0x456));
        assertEq(rHYPE.masterMinter(), address(0x456), "master minter");
    }

    function testUpdateMaxMintable() public {
        vm.prank(address(0x123));
        vm.expectRevert();
        rHYPE.setMaxMintable(1000);

        vm.prank(owner);
        rHYPE.setMaxMintable(1000);
        assertEq(rHYPE.maxMintable(), 1000, "max mintable");

        vm.expectRevert();
        rHYPE.setMaxMintable(500); // max mintable can only be increased from previous value.
    }

    function testUpdateOwner() public {
        vm.prank(address(0x123));
        vm.expectRevert();
        rHYPE.transferOwnership(address(0x456));

        vm.prank(owner);
        rHYPE.transferOwnership(address(0x456));
        assertEq(rHYPE.owner(), address(0x456), "owner");

        address attacker = address(0x999);
        vm.prank(attacker);
        vm.expectRevert();
        rHYPE.transferOwnership(attacker);
    }
}
