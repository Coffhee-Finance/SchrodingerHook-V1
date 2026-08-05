// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {HyperliquidPerpToken} from "../src/eAssets/HyperliquidPerpToken.sol";

contract DeployHyperliquidPerpToken is Script {
    function run() external returns (HyperliquidPerpToken token) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(privateKey);
        address initialOwner = vm.envOr("EASSET_OWNER", broadcaster);

        console2.log("Broadcaster:", broadcaster);
        console2.log("ERC-3475 owner:", initialOwner);

        vm.startBroadcast(privateKey);
        token = new HyperliquidPerpToken(initialOwner);
        vm.stopBroadcast();

        console2.log("HyperliquidPerpToken deployed:", address(token));
    }
}
