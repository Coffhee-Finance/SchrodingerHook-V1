// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {SchrodingerHook} from "../src/SchrodingerHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/**
 * @title DeploySchrodingerHook
 * @notice Mines a CREATE2 salt and deploys SchrodingerHook with exactly the
 *         Uniswap v4 BEFORE_SWAP and AFTER_SWAP address flags.
 *
 * Required environment variables:
 *   PRIVATE_KEY
 *   POOL_MANAGER
 *
 * Optional environment variables:
 *   SCHRODINGER_OWNER       defaults to broadcaster
 *   TELLOR_ADAPTER          defaults to address(0)
 *   HYPERLANE_RECEIVER      defaults to address(0)
 *   REACTIVE_ADAPTER        defaults to address(0)
 *   MAX_SALT_ITERATIONS     defaults to 1,000,000
 *
 * Important:
 * - When optional modules are supplied, SCHRODINGER_OWNER must equal the
 *   broadcaster because only the owner can approve modules after deployment.
 * - Token and bond whitelists are intentionally configured after deployment,
 *   once their contracts have been deployed and interface-checked.
 */
contract DeploySchrodingerHook is Script {
    // Foundry's canonical CREATE2 deterministic deployment proxy.
    address internal constant CREATE2_DEPLOYER =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);
    uint160 internal constant REQUIRED_FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

    uint256 internal constant DEFAULT_MAX_ITERATIONS = 1_000_000;

    error InvalidAddress();
    error HookSaltNotFound();
    error OwnerMustBeBroadcasterForModuleSetup();
    error UnexpectedDeploymentAddress(address predicted, address deployed);
    error UnexpectedHookFlags(uint160 expected, uint160 actual);

    function run() external returns (SchrodingerHook hook) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(privateKey);
        address poolManagerAddress = vm.envAddress("POOL_MANAGER");
        address initialOwner = vm.envOr("SCHRODINGER_OWNER", broadcaster);

        address tellorAdapter = vm.envOr("TELLOR_ADAPTER", address(0));
        address hyperlaneReceiver = vm.envOr("HYPERLANE_RECEIVER", address(0));
        address reactiveAdapter = vm.envOr("REACTIVE_ADAPTER", address(0));
        uint256 maxIterations = vm.envOr(
            "MAX_SALT_ITERATIONS",
            DEFAULT_MAX_ITERATIONS
        );

        if (poolManagerAddress == address(0) || initialOwner == address(0)) {
            revert InvalidAddress();
        }

        bool configureModules = tellorAdapter != address(0)
            || hyperlaneReceiver != address(0)
            || reactiveAdapter != address(0);

        if (configureModules && initialOwner != broadcaster) {
            revert OwnerMustBeBroadcasterForModuleSetup();
        }

        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManagerAddress),
            initialOwner
        );

        (address predicted, bytes32 salt) = findSalt(
            CREATE2_DEPLOYER,
            REQUIRED_FLAGS,
            type(SchrodingerHook).creationCode,
            constructorArgs,
            maxIterations
        );

        console2.log("Broadcaster:", broadcaster);
        console2.log("Initial owner:", initialOwner);
        console2.log("PoolManager:", poolManagerAddress);
        console2.log("Predicted SchrodingerHook:", predicted);
        console2.log("Required hook flags:", uint256(REQUIRED_FLAGS));
        console2.log("CREATE2 salt:");
        console2.logBytes32(salt);

        vm.startBroadcast(privateKey);

        hook = new SchrodingerHook{salt: salt}(
            IPoolManager(poolManagerAddress),
            initialOwner
        );

        if (tellorAdapter != address(0)) {
            hook.setProtocolModule(tellorAdapter, true);
        }
        if (hyperlaneReceiver != address(0)) {
            hook.setProtocolModule(hyperlaneReceiver, true);
        }
        if (reactiveAdapter != address(0)) {
            hook.setProtocolModule(reactiveAdapter, true);
        }

        vm.stopBroadcast();

        if (address(hook) != predicted) {
            revert UnexpectedDeploymentAddress(predicted, address(hook));
        }

        uint160 actualFlags = uint160(address(hook)) & ALL_HOOK_MASK;
        if (actualFlags != REQUIRED_FLAGS) {
            revert UnexpectedHookFlags(REQUIRED_FLAGS, actualFlags);
        }

        console2.log("SchrodingerHook deployed:", address(hook));
        console2.log("Actual hook flags:", uint256(actualFlags));
        console2.log("Tellor adapter:", tellorAdapter);
        console2.log("Hyperlane receiver:", hyperlaneReceiver);
        console2.log("Reactive adapter:", reactiveAdapter);
    }

    function findSalt(
        address create2Deployer,
        uint160 requiredFlags,
        bytes memory creationCode,
        bytes memory constructorArgs,
        uint256 maxIterations
    ) public pure returns (address predicted, bytes32 salt) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(creationCode, constructorArgs)
        );

        for (uint256 i; i < maxIterations; ++i) {
            salt = bytes32(i);
            predicted = computeCreate2Address(
                create2Deployer,
                salt,
                initCodeHash
            );

            if ((uint160(predicted) & ALL_HOOK_MASK) == requiredFlags) {
                return (predicted, salt);
            }
        }

        revert HookSaltNotFound();
    }

    function computeCreate2Address(
        address create2Deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) public pure returns (address predicted) {
        predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            create2Deployer,
                            salt,
                            initCodeHash
                        )
                    )
                )
            )
        );
    }
}
