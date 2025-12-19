// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../src/ReliqHYPE.sol";
import "../../src/Altar.sol";

// -----------------------------
// Mock Token
// -----------------------------
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Backing Token", "MOCK") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract PreDepositTest is Test {
    ReliqHYPE public reHYPE;
    Altar public altar;
    MockERC20 public backing;

    address owner = address(this);
    address treasury = makeAddr("treasury");
    address u1 = makeAddr("user1");
    address u2 = makeAddr("user2");
    address u3 = makeAddr("user3");

    function setUp() public {
        vm.label(owner, "Owner");
        vm.label(treasury, "Treasury");
        vm.label(u1, "User1");
        vm.label(u2, "User2");
        vm.label(u3, "User3");

        // Deploy Contracts
        backing = new MockERC20();
        reHYPE = new ReliqHYPE(IERC20(address(backing)));

        uint256 backingMintAmt = 100_000 ether;
        backing.mint(owner, backingMintAmt);
        backing.mint(u1, backingMintAmt);
        backing.mint(u2, backingMintAmt);
        backing.mint(u3, backingMintAmt);

        reHYPE.setTreasuryAddress(treasury);
    }

    function testHappyFlowNoWhitelist() public {
        backing.approve(address(reHYPE), type(uint256).max);
        reHYPE.setStart(1_000 ether, 1 ether);

        altar = new Altar(address(reHYPE), address(backing));
        reHYPE.setMasterMinter(address(altar));

        uint256 deadline = block.timestamp + 1 days;
        uint256 minContribution = 10 ether;
        uint256 maxContribution = 1_000 ether;
        uint256 depositCap = 10_000 ether;
        altar.kickOff(deadline, minContribution, maxContribution, depositCap);

        vm.startPrank(u1);
        backing.approve(address(altar), type(uint256).max);
        altar.sacrifice(500 ether, u1);
        vm.stopPrank();

        vm.startPrank(u2);
        backing.approve(address(altar), type(uint256).max);
        altar.sacrifice(700 ether, u2);
        vm.stopPrank();

        vm.startPrank(u3);
        backing.approve(address(altar), type(uint256).max);
        altar.sacrifice(800 ether, u3);
        vm.stopPrank();

        console.log("Total Contributions:", altar.totalContributions());
        console.log("U1 Contribution:", altar.userContributions(u1));
        console.log("U2 Contribution:", altar.userContributions(u2));
        console.log("U3 Contribution:", altar.userContributions(u3));

        console.log("//////////////");

        // Fast forward to after deadline
        vm.warp(deadline + 1);

        altar.enterTheTemple();

        console.log("reHYPE received by Altar:", reHYPE.balanceOf(address(altar)));

        vm.startPrank(u1);
        altar.receiveOffering();
        vm.stopPrank();

        vm.startPrank(u2);
        altar.receiveOffering();
        vm.stopPrank();

        vm.startPrank(u3);
        altar.receiveOffering();
        vm.stopPrank();

        console.log("//////////////");

        console.log("U1 reHYPE Balance:", reHYPE.balanceOf(u1));
        console.log("U2 reHYPE Balance:", reHYPE.balanceOf(u2));
        console.log("U3 reHYPE Balance:", reHYPE.balanceOf(u3));

        console.log("reHYPE price post vault:", reHYPE.AssetToBackingFloor(1 ether));
    }

    function testHappyFlowMultipleVaults() public {
        backing.approve(address(reHYPE), type(uint256).max);
        reHYPE.setStart(1_000 ether, 1 ether);

        Altar vault1 = new Altar(address(reHYPE), address(backing));
        reHYPE.setMasterMinter(address(vault1));

        uint256 minContribution = 10 ether;
        uint256 maxContribution = 50_000 ether;
        uint256 depositCap = 100_000 ether;
        uint256 deadlineV1 = block.timestamp + 1 days;

        console.log("reHYPE price pre Vault 1:", reHYPE.AssetToBackingFloor(1 ether));

        console.log("\n---- Vault 1 ----");
        vault1.kickOff(deadlineV1, minContribution, maxContribution, depositCap);

        vm.startPrank(u1);
        backing.approve(address(vault1), type(uint256).max);
        vault1.sacrifice(30_000 ether, u1);
        vm.stopPrank();

        // Fast forward to after deadline
        vm.warp(deadlineV1 + 1);
        vault1.enterTheTemple();
        console.log("reHYPE received by Vault 1:", reHYPE.balanceOf(address(vault1)));
        console.log("reHYPE price post Vault 1:", reHYPE.AssetToBackingFloor(1 ether));

        vm.startPrank(u1);
        vault1.receiveOffering();
        vm.stopPrank();

        console.log("U1 reHYPE Balance after Vault 1:", reHYPE.balanceOf(u1));

        console.log("\n---- Vault 2 ----");
        Altar vault2 = new Altar(address(reHYPE), address(backing));
        reHYPE.setMasterMinter(address(vault2));
        uint256 deadlineV2 = block.timestamp + 1 days;
        vault2.kickOff(deadlineV2, minContribution, maxContribution, depositCap);

        vm.startPrank(u1);
        backing.approve(address(vault2), type(uint256).max);
        vault2.sacrifice(20_000 ether, u1);
        vm.stopPrank();

        // Fast forward to after deadline
        vm.warp(deadlineV2 + 1);
        vault2.enterTheTemple();
        console.log("reHYPE received by Vault 2:", reHYPE.balanceOf(address(vault2)));
        console.log("reHYPE price post Vault 2:", reHYPE.AssetToBackingFloor(1 ether));

        vm.startPrank(u1);
        vault2.receiveOffering();
        vm.stopPrank();

        console.log("U1 reHYPE Balance after Vault 2:", reHYPE.balanceOf(u1));
    }

    function testAltarFlowWhitelist() public {
        backing.approve(address(reHYPE), type(uint256).max);
        reHYPE.setStart(1_000 ether, 1 ether);

        altar = new Altar(address(reHYPE), address(backing));
        reHYPE.setMasterMinter(address(altar));

        uint256 deadline = block.timestamp + 1 days;
        uint256 minContribution = 10 ether;
        uint256 maxContribution = 1_000 ether;
        uint256 depositCap = 10_000 ether;

        // Setup Whitelist
        address[] memory whitelistedUsers = new address[](3);
        whitelistedUsers[0] = u1;
        whitelistedUsers[1] = u2;
        whitelistedUsers[2] = u3;

        //Setup mint allowances
        uint256[] memory mintAllowances = new uint256[](3);
        mintAllowances[0] = 1_000 ether;
        mintAllowances[1] = 1_000 ether;
        mintAllowances[2] = 1_000 ether;

        vm.expectRevert();
        altar.setBulkMintAllowance(whitelistedUsers, mintAllowances); // this should fail as the whitelist is not active yet.

        altar.toggleWhitelist();
        altar.setBulkMintAllowance(whitelistedUsers, mintAllowances);

        altar.kickOff(deadline, minContribution, maxContribution, depositCap);

        vm.startPrank(u1);
        backing.approve(address(altar), type(uint256).max);
        altar.sacrifice(500 ether, u1);
        vm.stopPrank();

        vm.startPrank(u2);
        backing.approve(address(altar), type(uint256).max);
        altar.sacrifice(700 ether, u2);
        vm.stopPrank();

        vm.startPrank(u3);
        backing.approve(address(altar), type(uint256).max);
        altar.sacrifice(800 ether, u3);
        vm.stopPrank();
        console.log("Total Contributions:", altar.totalContributions());

        vm.warp(deadline + 1);

        altar.enterTheTemple();
        console.log("reHYPE received by Altar:", reHYPE.balanceOf(address(altar)));

        vm.startPrank(u1);
        altar.receiveOffering();
        vm.stopPrank();

        vm.startPrank(u2);
        altar.receiveOffering();
        vm.stopPrank();

        vm.startPrank(u3);
        altar.receiveOffering();
        vm.stopPrank();
    }
}
