// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../src/Altar.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// ------------------------------------------------------
/// Mock ReliqHYPE (ERC20 + mock buy)
/// ------------------------------------------------------
contract MockReliqHYPE is ERC20 {
    bool public buyCalled;
    uint256 public lastBuyAmount;

    constructor() ERC20("Mock ReliqHYPE", "MRH") {}

    function buy(address receiver, uint256 amountInBacking) external {
        buyCalled = true;
        lastBuyAmount = amountInBacking;
        // Simulate a successful ReliqHYPE mint (e.g. 2x backing)
        _mint(receiver, amountInBacking * 2);
    }
}

/// ------------------------------------------------------
/// Mock Backing Token (ERC20)
/// ------------------------------------------------------
contract MockBacking is ERC20 {
    constructor() ERC20("Mock Backing Token", "MBK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// ------------------------------------------------------
/// Altar Test
/// ------------------------------------------------------
contract AltarTest is Test {
    Altar altar;
    MockReliqHYPE reliq;
    MockBacking backing;

    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        reliq = new MockReliqHYPE();
        backing = new MockBacking();
        altar = new Altar(address(reliq), address(backing));

        // mint some backing tokens
        backing.mint(alice, 1000 ether);
        backing.mint(bob, 1000 ether);

        // owner kickoff
        uint256 deadline = block.timestamp + 3 days;
        altar.kickOff(deadline, 1 ether, 100 ether, 1000 ether);
    }

    // --------------------------------------------------
    // 1. Kickoff
    // --------------------------------------------------
    function testKickoffParams() public view {
        assertEq(altar.minContribution(), 1 ether);
        assertEq(altar.maxContribution(), 100 ether);
        assertEq(altar.depositCap(), 1000 ether);
        assertGt(altar.deadline(), block.timestamp);
    }

    // --------------------------------------------------
    // 2. Sacrifice
    // --------------------------------------------------
    function testSacrificeFlow() public {
        vm.startPrank(alice);
        backing.approve(address(altar), 10 ether);
        altar.sacrifice(10 ether, alice);
        vm.stopPrank();

        assertEq(altar.userContributions(alice), 10 ether);
        assertEq(altar.totalContributions(), 10 ether);
        assertEq(backing.balanceOf(address(altar)), 10 ether);
    }

    function testCannotSacrificeAfterDeadline() public {
        vm.warp(block.timestamp + 4 days);
        vm.startPrank(alice);
        backing.approve(address(altar), 10 ether);
        vm.expectRevert("Altar: deadline passed");
        altar.sacrifice(10 ether, alice);
        vm.stopPrank();
    }

    // --------------------------------------------------
    // 3. Unsacrifice
    // --------------------------------------------------
    function testUnsacrificeFlow() public {
        vm.startPrank(alice);
        backing.approve(address(altar), 20 ether);
        altar.sacrifice(20 ether, alice);
        altar.unsacrifice(5 ether);
        vm.stopPrank();

        assertEq(altar.userContributions(alice), 15 ether);
        assertEq(altar.totalContributions(), 15 ether);
        assertEq(backing.balanceOf(alice), 1000 ether - 15 ether);
    }

    // --------------------------------------------------
    // 4. Enter the Temple
    // --------------------------------------------------
    function testEnterTheTemple() public {
        vm.startPrank(alice);
        backing.approve(address(altar), 50 ether);
        altar.sacrifice(50 ether, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 4 days);

        altar.enterTheTemple();

        assertTrue(reliq.buyCalled(), "Buy not called");
        assertTrue(altar.isReliqHYPEClaim(), "Claim not enabled");
        assertGt(altar.totalReliqHYPEAcquired(), 0);
    }

    // --------------------------------------------------
    // 5. Claim Flow
    // --------------------------------------------------
    function testClaimOfferingEndToEnd() public {
        // Alice deposits
        vm.startPrank(alice);
        backing.approve(address(altar), 100 ether);
        altar.sacrifice(100 ether, alice);
        vm.stopPrank();

        // move past deadline
        vm.warp(block.timestamp + 4 days);
        altar.enterTheTemple();

        uint256 claimable = altar.claimableOffering(alice);
        assertGt(claimable, 0);

        uint256 beforeBal = reliq.balanceOf(alice);
        vm.prank(alice);
        altar.receiveOffering();
        uint256 afterBal = reliq.balanceOf(alice);

        assertEq(altar.userContributions(alice), 0);
        assertGt(afterBal, beforeBal);
    }

    // --------------------------------------------------
    // 6. Whitelist Tests
    // --------------------------------------------------
    function testWhitelistRestriction() public {
        vm.prank(owner);
        altar.toggleWhitelist();

        vm.prank(owner);
        altar.setMintAllowance(alice, 5 ether);

        vm.startPrank(alice);
        backing.approve(address(altar), 10 ether);
        vm.expectRevert("Altar: mint allowance exceeded");
        altar.sacrifice(10 ether, alice);

        altar.sacrifice(5 ether, alice);

        vm.stopPrank();

        vm.startPrank(bob);
        backing.approve(address(altar), 10 ether);
        vm.expectRevert();
        altar.sacrifice(10 ether, bob);
        vm.stopPrank();
    }

    function testBulkMintAllowance() public {
        // Setup multiple users
        address charlie = address(0xC4A21E);
        address dave = address(0xDA7E);
        backing.mint(charlie, 1000 ether);
        backing.mint(dave, 1000 ether);

        // Enable whitelist
        vm.prank(owner);
        altar.toggleWhitelist();

        // Set bulk mint allowances
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 20 ether;
        amounts[1] = 30 ether;
        amounts[2] = 40 ether;

        vm.prank(owner);
        altar.setBulkMintAllowance(users, amounts);

        // Test Alice can sacrifice up to her allowance
        vm.startPrank(alice);
        backing.approve(address(altar), 20 ether);
        altar.sacrifice(20 ether, alice);
        vm.stopPrank();

        // Test Bob can sacrifice up to his allowance
        vm.startPrank(bob);
        backing.approve(address(altar), 30 ether);
        altar.sacrifice(30 ether, bob);
        vm.stopPrank();

        // Test Charlie can sacrifice up to his allowance
        vm.startPrank(charlie);
        backing.approve(address(altar), 40 ether);
        altar.sacrifice(40 ether, charlie);
        vm.stopPrank();

        // Test Dave cannot sacrifice (not whitelisted)
        vm.startPrank(dave);
        backing.approve(address(altar), 10 ether);
        vm.expectRevert();
        altar.sacrifice(10 ether, dave);
        vm.stopPrank();
    }

    function testBulkMintAllowanceExceeded() public {
        // Enable whitelist
        vm.prank(owner);
        altar.toggleWhitelist();

        // Set bulk mint allowances
        address[] memory users = new address[](1);
        users[0] = alice;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 15 ether;

        vm.prank(owner);
        altar.setBulkMintAllowance(users, amounts);

        // Test Alice can sacrifice up to her allowance
        vm.startPrank(alice);
        backing.approve(address(altar), 20 ether);

        // First sacrifice within allowance
        altar.sacrifice(10 ether, alice);

        // Second sacrifice exceeds allowance
        vm.expectRevert("Altar: mint allowance exceeded");
        altar.sacrifice(10 ether, alice);

        // But can sacrifice remaining allowance
        altar.sacrifice(5 ether, alice);
        vm.stopPrank();
    }

    // --------------------------------------------------
    // 7. Recovery
    // --------------------------------------------------
    function testRecoverBackingAndReliq() public {
        vm.startPrank(alice);
        backing.approve(address(altar), 10 ether);
        altar.sacrifice(10 ether, alice);
        vm.stopPrank();

        altar.recoverERC20(address(backing));
        assertEq(backing.balanceOf(owner), 10 ether);
    }
}
