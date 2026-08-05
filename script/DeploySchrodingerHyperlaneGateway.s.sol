// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {
    SchrodingerHyperlaneGateway
} from "../src/reactive/SchrodingerHyperlaneGateway.sol";

/**
 * @title DeploySchrodingerHyperlaneGateway
 *
 * @notice Deploys the asset-chain gateway that:
 * - emits Schrodinger automation signals;
 * - receives authenticated Hyperlane messages;
 * - executes approved callbacks against registered markets.
 *
 * Required environment variables:
 *
 * PRIVATE_KEY
 * ASSET_HYPERLANE_MAILBOX
 * REACTIVE_HYPERLANE_DOMAIN
 *
 * Optional environment variables:
 *
 * GATEWAY_OWNER
 * TRUSTED_REACTIVE_SENDER
 */
contract DeploySchrodingerHyperlaneGateway is Script {
    function run()
        external
        returns (
            SchrodingerHyperlaneGateway gateway
        )
    {
        uint256 privateKey =
            vm.envUint("PRIVATE_KEY");

        address deployer =
            vm.addr(privateKey);

        address owner =
            vm.envOr(
                "GATEWAY_OWNER",
                deployer
            );

        address mailbox =
            vm.envAddress(
                "ASSET_HYPERLANE_MAILBOX"
            );

        uint32 reactiveDomain =
            uint32(
                vm.envUint(
                    "REACTIVE_HYPERLANE_DOMAIN"
                )
            );

        /*
         * This can initially remain bytes32(0) if the Reactive contract
         * has not been deployed yet.
         *
         * After deploying SchrodingerReactive, call:
         *
         * setTrustedReactiveEndpoint(
         *     reactiveDomain,
         *     bytes32(uint256(uint160(reactiveAddress)))
         * )
         */
        bytes32 reactiveSender =
            vm.envOr(
                "TRUSTED_REACTIVE_SENDER",
                bytes32(0)
            );

        console2.log(
            "Gateway deployer:",
            deployer
        );

        console2.log(
            "Gateway owner:",
            owner
        );

        console2.log(
            "Asset Hyperlane mailbox:",
            mailbox
        );

        console2.log(
            "Reactive Hyperlane domain:",
            reactiveDomain
        );

        console2.log(
            "Trusted Reactive sender:"
        );

        console2.logBytes32(
            reactiveSender
        );

        vm.startBroadcast(privateKey);

        gateway =
            new SchrodingerHyperlaneGateway(
                owner,
                mailbox,
                reactiveDomain,
                reactiveSender
            );

        vm.stopBroadcast();

        console2.log(
            "SchrodingerHyperlaneGateway:",
            address(gateway)
        );
    }
}