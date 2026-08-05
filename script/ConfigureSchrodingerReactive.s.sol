// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {
    SchrodingerHyperlaneGateway
} from "../src/reactive/SchrodingerHyperlaneGateway.sol";

/**
 * @title ConfigureSchrodingerReactive
 *
 * @notice Configures the asset-chain gateway after both the gateway and
 *         Reactive contracts have been deployed.
 *
 * It can:
 * - set the trusted Reactive domain and sender;
 * - register the ERC-20/ERC-7984 Schrodinger market;
 * - register the ERC-1155 Schrodinger market;
 * - approve the reactive-rebalance selector for both markets.
 *
 * Required environment variables:
 *
 * PRIVATE_KEY
 * SCHRODINGER_GATEWAY
 * SCHRODINGER_REACTIVE
 * REACTIVE_HYPERLANE_DOMAIN
 *
 * Optional environment variables:
 *
 * SCHRODINGER_ERC20_MARKET
 * SCHRODINGER_ERC1155_MARKET
 */
contract ConfigureSchrodingerReactive is Script {
    uint8 internal constant MARKET_TYPE_ERC20 =
        1;

    uint8 internal constant MARKET_TYPE_ERC1155 =
        2;

    function run() external {
        uint256 privateKey =
            vm.envUint("PRIVATE_KEY");

        address broadcaster =
            vm.addr(privateKey);

        SchrodingerHyperlaneGateway gateway =
            SchrodingerHyperlaneGateway(
                payable(
                    vm.envAddress(
                        "SCHRODINGER_GATEWAY"
                    )
                )
            );

        address reactive =
            vm.envAddress(
                "SCHRODINGER_REACTIVE"
            );

        uint32 reactiveDomain =
            uint32(
                vm.envUint(
                    "REACTIVE_HYPERLANE_DOMAIN"
                )
            );

        address erc20Market =
            vm.envOr(
                "SCHRODINGER_ERC20_MARKET",
                address(0)
            );

        address erc1155Market =
            vm.envOr(
                "SCHRODINGER_ERC1155_MARKET",
                address(0)
            );

        bytes4 rebalanceSelector =
            bytes4(
                keccak256(
                    "executeReactiveRebalance(bytes32,bytes)"
                )
            );

        bytes32 reactiveSender =
            bytes32(
                uint256(
                    uint160(reactive)
                )
            );

        console2.log(
            "Configuration broadcaster:",
            broadcaster
        );

        console2.log(
            "Gateway:",
            address(gateway)
        );

        console2.log(
            "Reactive contract:",
            reactive
        );

        console2.log(
            "Reactive Hyperlane domain:",
            reactiveDomain
        );

        console2.log(
            "ERC20 market:",
            erc20Market
        );

        console2.log(
            "ERC1155 market:",
            erc1155Market
        );

        console2.log(
            "Approved rebalance selector:"
        );

        console2.logBytes4(
            rebalanceSelector
        );

        vm.startBroadcast(privateKey);

        /*
         * Trust the deployed Reactive contract as the remote Hyperlane sender.
         */
        gateway.setTrustedReactiveEndpoint(
            reactiveDomain,
            reactiveSender
        );

        /*
         * Register and configure the ERC-20/ERC-7984 market when supplied.
         */
        if (erc20Market != address(0)) {
            gateway.registerMarket(
                erc20Market,
                MARKET_TYPE_ERC20
            );

            gateway.setAllowedSelector(
                erc20Market,
                rebalanceSelector,
                true
            );
        }

        /*
         * Register and configure the encrypted ERC-1155 market when supplied.
         */
        if (erc1155Market != address(0)) {
            gateway.registerMarket(
                erc1155Market,
                MARKET_TYPE_ERC1155
            );

            gateway.setAllowedSelector(
                erc1155Market,
                rebalanceSelector,
                true
            );
        }

        vm.stopBroadcast();

        console2.log(
            "Reactive integration configured."
        );

        console2.log(
            "Trusted Reactive sender:"
        );

        console2.logBytes32(
            reactiveSender
        );
    }
}