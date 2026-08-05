// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {HyperliquidPerpToken} from "../src/eAssets/HyperliquidPerpToken.sol";
import {CoffheeMarketToken} from "../src/eAssets/CoffheeMarketToken.sol";

/**
 * @notice Deploys the ERC-3475 perpetual token and encrypted ERC-1155 wrapper
 *         in one broadcast transaction sequence.
 */
contract DeployEAssets is Script {
    function run()
        external
        returns (
            HyperliquidPerpToken perpToken,
            CoffheeMarketToken marketToken
        )
    {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(privateKey);

        address initialOwner = vm.envOr("EASSET_OWNER", broadcaster);
        address schrodingerHook = vm.envOr("SCHRODINGER_HOOK", address(0));
        string memory baseURI = vm.envOr(
            "COFFHEE_MARKET_TOKEN_URI",
            string("ipfs://coffhee-market/{id}.json")
        );

        console2.log("Broadcaster:", broadcaster);
        console2.log("eAsset owner:", initialOwner);
        console2.log("SchrodingerHook:", schrodingerHook);

        vm.startBroadcast(privateKey);

        perpToken = new HyperliquidPerpToken(initialOwner);
        marketToken = new CoffheeMarketToken(initialOwner, perpToken, baseURI);

        if (schrodingerHook != address(0)) {
            marketToken.setSchrodingerHook(schrodingerHook);
        }

        vm.stopBroadcast();

        console2.log("HyperliquidPerpToken:", address(perpToken));
        console2.log("CoffheeMarketToken:", address(marketToken));
    }
}
