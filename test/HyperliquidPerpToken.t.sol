// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HyperliquidPerpToken, ERC3475} from "../src/eAssets/HyperliquidPerpToken.sol";

contract HyperliquidPerpTokenTest is Test {
    HyperliquidPerpToken internal token;

    address internal owner = makeAddr("owner");
    address internal issuer = makeAddr("issuer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal operator = makeAddr("operator");

    uint256 internal constant CLASS_ID = 1;
    uint256 internal constant NONCE_ID = 1001;
    uint256 internal constant UNIT = 1e6;

    function setUp() public {
        token = new HyperliquidPerpToken(owner);

        vm.prank(owner);
        token.setIssuer(issuer, true);

        vm.prank(owner);
        token.createClass(_classData());

        vm.prank(owner);
        token.createPerpSeries(CLASS_ID, NONCE_ID, _perpData());
    }

    function testConstructorConfiguration() public view {
        assertEq(token.owner(), owner);
        assertEq(token.name(), "Coffhee Hyperliquid Perpetual Assets");
        assertEq(token.symbol(), "HLPERP-3475");
        assertTrue(token.approvedIssuers(owner));
        assertTrue(token.approvedIssuers(issuer));
    }

    function testCreateClassAndSeries() public view {
        HyperliquidPerpToken.ClassData memory classInfo = token.classData(CLASS_ID);
        assertEq(classInfo.name, "Hyperliquid HYPE Perpetual");
        assertEq(classInfo.symbol, "HYPE-PERP");
        assertEq(classInfo.marketIdentifier, "HYPE-USDC-PERP");
        assertEq(classInfo.settlementDecimals, 6);
        assertTrue(classInfo.active);
        assertTrue(classInfo.exists);

        HyperliquidPerpToken.PerpData memory perp = token.perpData(CLASS_ID, NONCE_ID);
        assertEq(uint256(perp.side), uint256(HyperliquidPerpToken.PositionSide.LONG));
        assertEq(uint256(perp.marginMode), uint256(HyperliquidPerpToken.MarginMode.ISOLATED));
        assertEq(uint256(perp.status), uint256(HyperliquidPerpToken.PositionStatus.ACTIVE));
        assertEq(perp.entryPrice, 25e6);
        assertEq(perp.notionalValue, 10_000e6);
        assertTrue(perp.transferable);
        assertTrue(perp.redeemable);
        assertTrue(perp.exists);
    }

    function testIssuerCanIssue() public {
        ERC3475.Transaction[] memory items = _singleTransaction(500 * UNIT);

        vm.prank(issuer);
        token.issue(alice, items);

        assertEq(token.balanceOf(alice, CLASS_ID, NONCE_ID), 500 * UNIT);
        assertEq(token.totalSupply(CLASS_ID, NONCE_ID), 500 * UNIT);
    }

    function testUnapprovedIssuerCannotIssue() public {
        ERC3475.Transaction[] memory items = _singleTransaction(UNIT);

        vm.prank(alice);
        vm.expectRevert(HyperliquidPerpToken.Unauthorized.selector);
        token.issue(alice, items);
    }

    function testOwnerCanManageIssuer() public {
        address secondIssuer = makeAddr("secondIssuer");

        vm.prank(owner);
        token.setIssuer(secondIssuer, true);
        assertTrue(token.approvedIssuers(secondIssuer));

        vm.prank(owner);
        token.setIssuer(secondIssuer, false);
        assertFalse(token.approvedIssuers(secondIssuer));
    }

    function testHolderCanTransfer() public {
        _issueTo(alice, 100 * UNIT);
        ERC3475.Transaction[] memory items = _singleTransaction(40 * UNIT);

        vm.prank(alice);
        token.transferFrom(alice, bob, items);

        assertEq(token.balanceOf(alice, CLASS_ID, NONCE_ID), 60 * UNIT);
        assertEq(token.balanceOf(bob, CLASS_ID, NONCE_ID), 40 * UNIT);
        assertEq(token.totalSupply(CLASS_ID, NONCE_ID), 100 * UNIT);
    }

    function testApprovedOperatorCanTransfer() public {
        _issueTo(alice, 100 * UNIT);

        vm.prank(alice);
        token.setApprovalFor(operator, true);
        assertTrue(token.isApprovedFor(alice, operator));

        vm.prank(operator);
        token.transferFrom(alice, bob, _singleTransaction(25 * UNIT));

        assertEq(token.balanceOf(alice, CLASS_ID, NONCE_ID), 75 * UNIT);
        assertEq(token.balanceOf(bob, CLASS_ID, NONCE_ID), 25 * UNIT);
    }

    function testUnauthorizedOperatorCannotTransfer() public {
        _issueTo(alice, 100 * UNIT);

        vm.prank(operator);
        vm.expectRevert(HyperliquidPerpToken.Unauthorized.selector);
        token.transferFrom(alice, bob, _singleTransaction(UNIT));
    }

    function testHolderCanRedeem() public {
        _issueTo(alice, 100 * UNIT);

        vm.prank(alice);
        token.redeem(alice, _singleTransaction(30 * UNIT));

        assertEq(token.balanceOf(alice, CLASS_ID, NONCE_ID), 70 * UNIT);
        assertEq(token.totalSupply(CLASS_ID, NONCE_ID), 70 * UNIT);
    }

    function testOwnerCanUpdateMarketSnapshot() public {
        vm.warp(1_800_000_000);

        vm.prank(owner);
        token.updateMarketSnapshot(
            CLASS_ID,
            NONCE_ID,
            30e6,
            20e6,
            -15,
            HyperliquidPerpToken.PositionStatus.ACTIVE,
            false,
            true
        );

        HyperliquidPerpToken.PerpData memory perp = token.perpData(CLASS_ID, NONCE_ID);
        assertEq(perp.markPriceAtIssuance, 30e6);
        assertEq(perp.liquidationPrice, 20e6);
        assertEq(perp.fundingRateBps, -15);
        assertFalse(perp.transferable);
        assertTrue(perp.redeemable);
        assertEq(perp.lastUpdatedAt, block.timestamp);
    }

    function testInactiveClassPreventsNewSeries() public {
        vm.prank(owner);
        token.setClassStatus(CLASS_ID, false);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HyperliquidPerpToken.ClassInactive.selector, CLASS_ID));
        token.createPerpSeries(CLASS_ID, 2002, _perpData());
    }

    function _issueTo(address recipient, uint256 amount) internal {
        vm.prank(issuer);
        token.issue(recipient, _singleTransaction(amount));
    }

    function _singleTransaction(
        uint256 amount
    ) internal pure returns (ERC3475.Transaction[] memory items) {
        items = new ERC3475.Transaction[](1);
        items[0] = ERC3475.Transaction({
            classId: CLASS_ID,
            nonceId: NONCE_ID,
            amount: amount
        });
    }

    function _classData() internal pure returns (HyperliquidPerpToken.ClassData memory) {
        return HyperliquidPerpToken.ClassData({
            name: "Hyperliquid HYPE Perpetual",
            symbol: "HYPE-PERP",
            underlyingAsset: "HYPE",
            quoteAsset: "USDC",
            venue: "Hyperliquid",
            marketIdentifier: "HYPE-USDC-PERP",
            settlementDecimals: 6,
            active: true,
            exists: false
        });
    }

    function _perpData() internal view returns (HyperliquidPerpToken.PerpData memory) {
        return HyperliquidPerpToken.PerpData({
            side: HyperliquidPerpToken.PositionSide.LONG,
            marginMode: HyperliquidPerpToken.MarginMode.ISOLATED,
            status: HyperliquidPerpToken.PositionStatus.ACTIVE,
            openedAt: uint64(block.timestamp),
            expiryOrReviewTime: uint64(block.timestamp + 30 days),
            lastUpdatedAt: 0,
            maxLeverageBps: 100_000,
            maintenanceMarginBps: 500,
            initialMarginBps: 1_000,
            liquidationFeeBps: 100,
            entryPrice: 25e6,
            markPriceAtIssuance: 25e6,
            liquidationPrice: 22e6,
            notionalValue: 10_000e6,
            collateralValue: 1_000e6,
            fundingRateBps: 10,
            externalPositionId: keccak256("hyperliquid-position-1001"),
            oracleMarketId: keccak256("HYPE-USDC-PERP"),
            publicMetadataURI: "ipfs://hyperliquid-perp-1001",
            transferable: true,
            redeemable: true,
            exists: false
        });
    }
}
