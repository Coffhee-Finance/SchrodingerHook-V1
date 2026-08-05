// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {
    SchrodingerReactive
} from "../src/reactive/SchrodingerReactive.sol";

/**
 * @title DeploySchrodingerReactive
 *
 * @notice Deploys the Reactive Network contract that:
 * - subscribes to SchrodingerMarketSignal events;
 * - converts MarketSignal values into ReactiveCommand values;
 * - dispatches commands through Hyperlane.
 *
 * Required environment variables:
 *
 * PRIVATE_KEY
 * REACTIVE_HYPERLANE_MAILBOX
 * ASSET_CHAIN_ID
 * ASSET_HYPERLANE_DOMAIN
 * SCHRODINGER_GATEWAY
 *
 * Optional environment variable:
 *
 * REACTIVE_INITIAL_FUNDING
 */
contract DeploySchrodingerReactive is Script {
    function run()
        external
        returns (
            SchrodingerReactive reactive
        )
    {
        uint256 privateKey =
            vm.envUint("PRIVATE_KEY");

        address deployer =
            vm.addr(privateKey);

        address mailbox =
            vm.envAddress(
                "REACTIVE_HYPERLANE_MAILBOX"
            );

        uint256 assetChainId =
            vm.envUint(
                "ASSET_CHAIN_ID"
            );

        uint32 assetDomain =
            uint32(
                vm.envUint(
                    "ASSET_HYPERLANE_DOMAIN"
                )
            );

        address gateway =
            vm.envAddress(
                "SCHRODINGER_GATEWAY"
            );

        uint256 initialFunding =
            vm.envOr(
                "REACTIVE_INITIAL_FUNDING",
                uint256(0)
            );

        console2.log(
            "Reactive deployer:",
            deployer
        );

        console2.log(
            "Reactive Hyperlane mailbox:",
            mailbox
        );

        console2.log(
            "Observed asset chain ID:",
            assetChainId
        );

        console2.log(
            "Asset Hyperlane domain:",
            assetDomain
        );

        console2.log(
            "Schrodinger gateway:",
            gateway
        );

        console2.log(
            "Initial native funding:",
            initialFunding
        );

        vm.startBroadcast(privateKey);

        reactive =
            new SchrodingerReactive{
                value: initialFunding
            }(
                mailbox,
                assetChainId,
                assetDomain,
                gateway
            );

        vm.stopBroadcast();

        console2.log(
            "SchrodingerReactive:",
            address(reactive)
        );
    }
}