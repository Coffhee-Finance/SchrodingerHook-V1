// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {HyperliquidPerpToken} from "../src/eAssets/HyperliquidPerpToken.sol";
import {CoffheeMarketToken} from "../src/eAssets/CoffheeMarketToken.sol";

contract DeployCoffheeMarketToken is Script {
    function run() external returns (CoffheeMarketToken marketToken) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(privateKey);

        address initialOwner = vm.envOr("EASSET_OWNER", broadcaster);
        address underlyingAddress = vm.envAddress("HYPERLIQUID_PERP_TOKEN");
        address schrodingerHook = vm.envOr("SCHRODINGER_HOOK", address(0));
        string memory baseURI = vm.envOr(
            "COFFHEE_MARKET_TOKEN_URI",
            string("ipfs://coffhee-market/{id}.json")
        );

        console2.log("Broadcaster:", broadcaster);
        console2.log("CoffheeMarketToken owner:", initialOwner);
        console2.log("Underlying ERC-3475:", underlyingAddress);
        console2.log("SchrodingerHook:", schrodingerHook);
        console2.log("Base URI:", baseURI);

        vm.startBroadcast(privateKey);

        marketToken = new CoffheeMarketToken(
            initialOwner,
            HyperliquidPerpToken(underlyingAddress),
            baseURI
        );

        if (schrodingerHook != address(0)) {
            marketToken.setSchrodingerHook(schrodingerHook);
        }

        vm.stopBroadcast();

        console2.log("CoffheeMarketToken deployed:", address(marketToken));
    }
}
