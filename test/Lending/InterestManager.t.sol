// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {InterestManager} from "../../src/InterestManager.sol";

contract InterestManagerTest is Test {
    InterestManager mgr;
    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        mgr = new InterestManager(500); // 5%
    }

    function testDefaultRate() public view {
        uint256 rate = mgr.defaultBaseRateBPS();
        assertEq(rate, 500);
    }

    function testSetDefaultRate() public {
        mgr.setDefaultBaseRate(700);
        assertEq(mgr.defaultBaseRateBPS(), 700);
    }

    function testSetUserRate() public {
        mgr.setUserBaseRate(alice, 600);
        assertEq(mgr.userBaseRateBPS(alice), 600);
    }

    function testUnsetUserRate() public {
        mgr.setUserBaseRate(alice, 600);
        assertEq(mgr.getInterestRateBPS(alice), 600);
        mgr.unsetUserBaseRate(alice);
        assertEq(mgr.userBaseRateBPS(alice), 0);
        assertEq(mgr.getInterestRateBPS(alice), mgr.defaultBaseRateBPS());
    }

    function testBulkUserRates() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        uint256[] memory bps = new uint256[](2);
        bps[0] = 650;
        bps[1] = 700;
        mgr.setBulkUserBaseRates(users, bps);

        assertEq(mgr.userBaseRateBPS(alice), 650);
        assertEq(mgr.userBaseRateBPS(bob), 700);
    }

    function testGetInterestRateBPS() public view {
        uint256 rateAlice = mgr.getInterestRateBPS(alice);
        uint256 rateBob = mgr.getInterestRateBPS(bob);
        assertEq(rateAlice, mgr.defaultBaseRateBPS());
        assertEq(rateBob, mgr.defaultBaseRateBPS());
    }

    function testBounds() public {
        vm.expectRevert(bytes("InterestManager: rate too low"));
        mgr.setDefaultBaseRate(9);

        vm.expectRevert(bytes("InterestManager: rate too high"));
        mgr.setDefaultBaseRate(10001);

        vm.expectRevert(bytes("InterestManager: rate too low"));
        mgr.setUserBaseRate(alice, 9);

        vm.expectRevert(bytes("InterestManager: rate too high"));
        mgr.setUserBaseRate(alice, 10001);
    }

    function testBulkBoundsAndLengths() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        uint256[] memory bps = new uint256[](2);
        bps[0] = 10;
        bps[1] = 10001;

        vm.expectRevert(bytes("InterestManager: rate too high"));
        mgr.setBulkUserBaseRates(users, bps);

        address[] memory users2 = new address[](1);
        users2[0] = alice;
        uint256[] memory bps2 = new uint256[](2);
        bps2[0] = 500;
        bps2[1] = 600;

        vm.expectRevert(bytes("InterestManager: invalid lengths"));
        mgr.setBulkUserBaseRates(users2, bps2);
    }
}
