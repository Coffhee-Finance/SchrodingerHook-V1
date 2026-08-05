// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HyperliquidPerpToken} from "../src/eAssets/HyperliquidPerpToken.sol";
import {CoffheeMarketToken} from "../src/eAssets/CoffheeMarketToken.sol";

/**
 * @notice Unit tests for the non-FHE administrative and integration surface.
 * @dev Encryption-input and ACL tests should run with Fhenix's CoFHE testing
 *      environment because ordinary local EVM execution does not provide the
 *      CoFHE coprocessor/precompile behavior used by wrap().
 */
contract CoffheeMarketTokenTest is Test {
    HyperliquidPerpToken internal underlying;
    CoffheeMarketToken internal marketToken;

    address internal owner = makeAddr("owner");
    address internal hook = makeAddr("schrodingerHook");
    address internal pool = makeAddr("pool");
    address internal attacker = makeAddr("attacker");

    string internal constant BASE_URI = "ipfs://coffhee-market/{id}.json";

    function setUp() public {
        underlying = new HyperliquidPerpToken(owner);
        marketToken = new CoffheeMarketToken(owner, underlying, BASE_URI);
    }

    function testConstructorConfiguration() public view {
        assertEq(marketToken.owner(), owner);
        assertEq(address(marketToken.underlying()), address(underlying));
        assertEq(marketToken.nextTokenId(), 1);
        assertEq(marketToken.uri(1), BASE_URI);
    }

    function testOwnerCanSetSchrodingerHook() public {
        vm.prank(owner);
        marketToken.setSchrodingerHook(hook);

        assertEq(marketToken.schrodingerHook(), hook);
        assertTrue(marketToken.approvedPoolOperators(hook));
    }

    function testNonOwnerCannotSetSchrodingerHook() public {
        vm.prank(attacker);
        vm.expectRevert();
        marketToken.setSchrodingerHook(hook);
    }

    function testOwnerCanManagePoolOperator() public {
        vm.prank(owner);
        marketToken.setPoolOperator(pool, true);
        assertTrue(marketToken.approvedPoolOperators(pool));

        vm.prank(owner);
        marketToken.setPoolOperator(pool, false);
        assertFalse(marketToken.approvedPoolOperators(pool));
    }

    function testNonOwnerCannotManagePoolOperator() public {
        vm.prank(attacker);
        vm.expectRevert();
        marketToken.setPoolOperator(pool, true);
    }

    function testOwnerCanUpdateURI() public {
        string memory newURI = "https://metadata.coffhee.finance/eassets/{id}.json";

        vm.prank(owner);
        marketToken.setURI(newURI);

        assertEq(marketToken.uri(42), newURI);
    }

    function testRejectsZeroHook() public {
        vm.prank(owner);
        vm.expectRevert(CoffheeMarketToken.ZeroAddress.selector);
        marketToken.setSchrodingerHook(address(0));
    }

    function testRejectsZeroPoolOperator() public {
        vm.prank(owner);
        vm.expectRevert(CoffheeMarketToken.ZeroAddress.selector);
        marketToken.setPoolOperator(address(0), true);
    }

    function testUnknownTokenIsNotSchrodingerEligible() public view {
        assertFalse(marketToken.isSchrodingerEligible(999));
    }
}
