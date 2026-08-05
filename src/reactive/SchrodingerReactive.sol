// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractPayer} from "reactive-lib/abstract-base/AbstractPayer.sol";
import {IPayer} from "reactive-lib/interfaces/IPayer.sol";

import {
    AbstractReactive
} from "reactive-lib/abstract-base/AbstractReactive.sol";

import {
    AbstractCallback
} from "reactive-lib/abstract-base/AbstractCallback.sol";

import {
    IHyperlaneMailbox
} from "./interfaces/IHyperlaneMailbox.sol";

/**
 * @title SchrodingerReactive
 * @author Coffhee Finance
 *
 * @notice
 * Fully automated Reactive Network and Hyperlane integration for
 * Schrodinger asset markets.
 *
 * This contract works with:
 *
 * 1. Schrodinger ERC-20 / ERC-7984 markets
 * 2. Schrodinger ERC-1155 / CoffheeMarketToken markets
 *
 * The originating market supplies the final callback calldata inside the
 * MarketSignal.callbackData field.
 *
 * The Reactive contract:
 *
 * 1. Observes SchrodingerMarketSignal(bytes).
 * 2. Decodes and validates the MarketSignal.
 * 3. Converts it into a ReactiveCommand.
 * 4. Emits a Reactive Callback.
 * 5. Dispatches the ReactiveCommand through Hyperlane.
 *
 * The destination SchrodingerHyperlaneGateway:
 *
 * 1. Authenticates the Hyperlane mailbox.
 * 2. Authenticates this Reactive contract as the sender.
 * 3. Confirms that the target market is registered.
 * 4. Confirms that the callback selector is approved.
 * 5. Executes the callback against the target market.
 */
contract SchrodingerReactive is AbstractReactive, AbstractCallback {
    // =============================================================
    //                           CONSTANTS
    // =============================================================

    /**
     * @notice Current protocol message version.
     */
    uint8 public constant MESSAGE_VERSION = 1;

    /**
     * @notice Schrodinger ERC-20/ERC-7984 market identifier.
     */
    uint8 public constant MARKET_TYPE_ERC20 = 1;

    /**
     * @notice Schrodinger ERC-1155 market identifier.
     */
    uint8 public constant MARKET_TYPE_ERC1155 = 2;

    /**
     * @notice Reactive Network topic for:
     *
     * SchrodingerMarketSignal(bytes)
     */
    uint256 public constant MARKET_SIGNAL_TOPIC_0 =
        uint256(
            keccak256(
                "SchrodingerMarketSignal(bytes)"
            )
        );

    /**
     * @notice Gas limit provided to the Reactive callback.
     */
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    // =============================================================
    //                            STRUCTS
    // =============================================================

    /**
     * @notice Signal emitted by SchrodingerHyperlaneGateway.
     *
     * @dev
     * This struct must exactly match the MarketSignal struct used by
     * SchrodingerHyperlaneGateway.
     */
    struct MarketSignal {
        uint8 version;
        uint256 sourceChainId;
        address sourceGateway;
        address sourceMarket;
        uint8 marketType;
        bytes32 marketId;
        uint8 action;
        uint256 nonce;
        uint256 timestamp;
        bytes callbackData;
    }

    /**
     * @notice Command delivered to SchrodingerHyperlaneGateway.
     *
     * @dev
     * This struct must exactly match the ReactiveCommand struct used by
     * SchrodingerHyperlaneGateway.
     */
    struct ReactiveCommand {
        uint8 version;
        bytes32 commandId;
        address targetMarket;
        uint8 marketType;
        bytes32 marketId;
        uint8 action;
        uint256 signalNonce;
        bytes callData;
    }

    // =============================================================
    //                            STORAGE
    // =============================================================

    /**
     * @notice Administrator of the Reactive contract.
     */
    address public owner;

    /**
     * @notice Hyperlane Mailbox deployed on Reactive Network.
     */
    IHyperlaneMailbox public immutable mailbox;

    /**
     * @notice EVM chain ID where the Schrodinger gateway is deployed.
     *
     * Reactive Network uses this value for event subscriptions.
     *
     * Example:
     * Arbitrum Sepolia chain ID = 421614
     */
    uint256 public immutable assetChainId;

    /**
     * @notice Hyperlane domain of the destination asset chain.
     *
     * Do not automatically assume that every Hyperlane domain is equal
     * to the EVM chain ID.
     */
    uint32 public immutable assetDomain;

    /**
     * @notice SchrodingerHyperlaneGateway deployed on the asset chain.
     */
    address public immutable assetGateway;

    /**
     * @notice Gateway address converted to Hyperlane bytes32 format.
     */
    bytes32 public immutable assetGatewayRecipient;

    /**
     * @notice Number of signals converted into commands by this contract.
     *
     * This value is primarily useful for observability.
     */
    uint256 public observedSignalCount;

    /**
     * @notice Tracks command IDs created during normal contract execution.
     *
     * @dev
     * Final replay protection must also be enforced by the asset-chain
     * gateway because Reactive VM execution and normal EVM execution use
     * different execution contexts.
     */
    mapping(bytes32 commandId => bool created) public createdCommands;

    // =============================================================
    //                             EVENTS
    // =============================================================

    event OwnerTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /**
     * @notice Emitted when the Reactive VM observes and validates a signal.
     */
    event MarketSignalObserved(
        bytes32 indexed commandId,
        uint256 indexed sourceChainId,
        address indexed sourceMarket,
        uint8 marketType,
        bytes32 marketId,
        uint8 action,
        uint256 signalNonce
    );

    /**
     * @notice Emitted when a signal has been converted into a command.
     */
    event ReactiveCommandCreated(
        bytes32 indexed commandId,
        address indexed targetMarket,
        uint8 indexed marketType,
        bytes32 marketId,
        uint8 action,
        uint256 signalNonce,
        bytes callData
    );

    /**
     * @notice Emitted when Hyperlane dispatches the command.
     */
    event HyperlaneCommandDispatched(
        bytes32 indexed messageId,
        bytes32 indexed commandId,
        uint32 indexed destinationDomain,
        bytes32 recipient,
        uint256 fee
    );

    /**
     * @notice Emitted when the contract receives native currency.
     */
    event NativeCurrencyReceived(
        address indexed sender,
        uint256 amount
    );

    /**
     * @notice Emitted when the owner withdraws native currency.
     */
    event NativeCurrencyWithdrawn(
        address indexed recipient,
        uint256 amount
    );

    // =============================================================
    //                             ERRORS
    // =============================================================

    error NotOwner(address caller);

    error ZeroAddress();

    error InvalidSourceChain(
        uint256 received,
        uint256 expected
    );

    error InvalidSourceGateway(
        address received,
        address expected
    );

    error InvalidLogContract(
        address received,
        address expected
    );

    error InvalidLogChain(
        uint256 received,
        uint256 expected
    );

    error InvalidMessageVersion(
        uint8 received,
        uint8 expected
    );

    error InvalidMarketType(
        uint8 marketType
    );

    error InvalidSourceMarket();

    error InvalidMarketId();

    error InvalidSignalNonce();

    error InvalidSignalTimestamp();

    error EmptyCallbackData();

    error InvalidCallbackDataLength(
        uint256 length
    );

    error InsufficientHyperlaneFee(
        uint256 available,
        uint256 required
    );

    error CommandAlreadyCreated(
        bytes32 commandId
    );

    error NativeTransferFailed();

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    /**
     * @param mailbox_ Hyperlane Mailbox on Reactive Network.
     * @param assetChainId_ EVM chain ID of the Schrodinger asset chain.
     * @param assetDomain_ Hyperlane destination domain of the asset chain.
     * @param assetGateway_ SchrodingerHyperlaneGateway on the asset chain.
     */
    constructor(
        address mailbox_,
        uint256 assetChainId_,
        uint32 assetDomain_,
        address assetGateway_
    )
        payable
        AbstractCallback(address(SERVICE_ADDR))
    {
        if (
            mailbox_ == address(0) ||
            assetGateway_ == address(0)
        ) {
            revert ZeroAddress();
        }

        owner = msg.sender;

        mailbox = IHyperlaneMailbox(mailbox_);

        assetChainId = assetChainId_;
        assetDomain = assetDomain_;
        assetGateway = assetGateway_;

        assetGatewayRecipient =
            bytes32(uint256(uint160(assetGateway_)));

        /*
         * `vm` is true when this contract is executing inside the
         * Reactive Virtual Machine.
         *
         * The subscription should only be registered during the normal
         * deployment context.
         */
        if (!vm) {
            service.subscribe(
                assetChainId_,
                assetGateway_,
                MARKET_SIGNAL_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    // =============================================================
    //                           MODIFIERS
    // =============================================================

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner(msg.sender);
        }

        _;
    }

    // =============================================================
    //                     REACTIVE AUTOMATION
    // =============================================================

    /**
     * @notice Called automatically by Reactive Network when the gateway
     * emits SchrodingerMarketSignal(bytes).
     *
     * @param log Reactive Network log record.
     *
     * The full automation occurs here:
     *
     * 1. Validate the log origin.
     * 2. Decode the dynamic bytes event argument.
     * 3. Decode the MarketSignal.
     * 4. Validate the MarketSignal.
     * 5. Generate a deterministic command ID.
     * 6. Construct the ReactiveCommand.
     * 7. Encode the command.
     * 8. Schedule callback() through Reactive Network.
     */
    function react(
        LogRecord calldata log
    )
        external
        vmOnly
    {
        _validateLogOrigin(log);

        /*
         * The gateway event is:
         *
         * event SchrodingerMarketSignal(bytes envelope);
         *
         * A dynamic bytes event argument is represented inside log.data
         * as ABI-encoded bytes.
         */
        bytes memory envelope = abi.decode(
            log.data,
            (bytes)
        );

        MarketSignal memory signal = abi.decode(
            envelope,
            (MarketSignal)
        );

        _validateSignal(signal);

        bytes32 commandId = _calculateCommandId(signal);

        ReactiveCommand memory command = ReactiveCommand({
            version: MESSAGE_VERSION,
            commandId: commandId,
            targetMarket: signal.sourceMarket,
            marketType: signal.marketType,
            marketId: signal.marketId,
            action: signal.action,
            signalNonce: signal.nonce,
            callData: signal.callbackData
        });

        bytes memory commandBody = abi.encode(command);

        emit MarketSignalObserved(
            commandId,
            signal.sourceChainId,
            signal.sourceMarket,
            signal.marketType,
            signal.marketId,
            signal.action,
            signal.nonce
        );

        emit ReactiveCommandCreated(
            commandId,
            command.targetMarket,
            command.marketType,
            command.marketId,
            command.action,
            command.signalNonce,
            command.callData
        );

        /*
         * Reactive Network will invoke:
         *
         * callback(address rvmId, bytes commandBody)
         *
         * The address(0) placeholder is replaced/validated through the
         * Reactive callback authorization mechanism.
         */
        bytes memory callbackPayload =
            abi.encodeWithSelector(
                this.callback.selector,
                address(0),
                commandBody
            );

        emit Callback(
            block.chainid,
            address(this),
            CALLBACK_GAS_LIMIT,
            callbackPayload
        );
    }

    /**
     * @notice Authorized Reactive callback.
     *
     * Reactive Network invokes this function after react() emits Callback.
     * It sends the already-constructed command through Hyperlane.
     *
     * @param rvmId Reactive VM identifier.
     * @param commandBody ABI-encoded ReactiveCommand.
     */
    function callback(
        address rvmId,
        bytes calldata commandBody
    )
        external
        authorizedSenderOnly
        rvmIdOnly(rvmId)
    {
        ReactiveCommand memory command = abi.decode(
            commandBody,
            (ReactiveCommand)
        );

        _validateCommand(command);

        _dispatchCommand(
            command,
            commandBody
        );
    }

    // =============================================================
    //                      DIRECT ADMINISTRATIVE SEND
    // =============================================================

    /**
     * @notice Sends a preconstructed ReactiveCommand directly.
     *
     * @dev
     * This bypasses event observation but does not bypass the destination
     * gateway's authentication, market registration, selector whitelist,
     * or replay protection.
     *
     * Useful for:
     *
     * - deployment testing;
     * - emergency execution;
     * - manual recovery;
     * - verifying Hyperlane configuration.
     */
    function sendCommand(
        ReactiveCommand calldata command
    )
        external
        onlyOwner
        returns (bytes32 messageId)
    {
        _validateCommand(command);

        bytes memory commandBody = abi.encode(command);

        messageId = _dispatchCommand(
            command,
            commandBody
        );
    }

    /**
     * @notice Constructs and sends a manual command.
     */
    function createAndSendCommand(
        address targetMarket,
        uint8 marketType,
        bytes32 marketId,
        uint8 action,
        uint256 signalNonce,
        bytes calldata callData
    )
        external
        onlyOwner
        returns (
            bytes32 commandId,
            bytes32 messageId
        )
    {
        if (targetMarket == address(0)) {
            revert InvalidSourceMarket();
        }

        if (!_isSupportedMarketType(marketType)) {
            revert InvalidMarketType(marketType);
        }

        if (callData.length < 4) {
            revert InvalidCallbackDataLength(
                callData.length
            );
        }

        commandId = keccak256(
            abi.encode(
                MESSAGE_VERSION,
                block.chainid,
                address(this),
                targetMarket,
                marketType,
                marketId,
                action,
                signalNonce,
                callData
            )
        );

        ReactiveCommand memory command = ReactiveCommand({
            version: MESSAGE_VERSION,
            commandId: commandId,
            targetMarket: targetMarket,
            marketType: marketType,
            marketId: marketId,
            action: action,
            signalNonce: signalNonce,
            callData: callData
        });

        bytes memory commandBody = abi.encode(command);

        messageId = _dispatchCommand(
            command,
            commandBody
        );
    }

    // =============================================================
    //                         HYPERLANE LOGIC
    // =============================================================

    /**
     * @notice Dispatches a ReactiveCommand through Hyperlane.
     */
    function _dispatchCommand(
        ReactiveCommand memory command,
        bytes memory commandBody
    )
        internal
        returns (bytes32 messageId)
    {
        /*
         * This is normal EVM execution, so this mapping can prevent a
         * duplicate callback or duplicate manual send from this instance.
         *
         * The destination gateway must still maintain its own replay
         * protection because it is the final execution authority.
         */
        if (createdCommands[command.commandId]) {
            revert CommandAlreadyCreated(
                command.commandId
            );
        }

        uint256 fee = mailbox.quoteDispatch(
            assetDomain,
            assetGatewayRecipient,
            commandBody
        );

        uint256 availableBalance = address(this).balance;

        if (availableBalance < fee) {
            revert InsufficientHyperlaneFee(
                availableBalance,
                fee
            );
        }

        createdCommands[command.commandId] = true;

        unchecked {
            ++observedSignalCount;
        }

        messageId = mailbox.dispatch{value: fee}(
            assetDomain,
            assetGatewayRecipient,
            commandBody
        );

        emit HyperlaneCommandDispatched(
            messageId,
            command.commandId,
            assetDomain,
            assetGatewayRecipient,
            fee
        );
    }

    // =============================================================
    //                         VALIDATION
    // =============================================================

    /**
     * @notice Confirms that Reactive Network delivered a log from the
     * expected chain and gateway.
     */
    function _validateLogOrigin(
        LogRecord calldata log
    )
        internal
        view
    {
        if (log.chain_id != assetChainId) {
            revert InvalidLogChain(
                log.chain_id,
                assetChainId
            );
        }

        if (log._contract != assetGateway) {
            revert InvalidLogContract(
                log._contract,
                assetGateway
            );
        }
    }

    /**
     * @notice Validates a decoded MarketSignal.
     */
    function _validateSignal(
        MarketSignal memory signal
    )
        internal
        view
    {
        if (signal.version != MESSAGE_VERSION) {
            revert InvalidMessageVersion(
                signal.version,
                MESSAGE_VERSION
            );
        }

        if (signal.sourceChainId != assetChainId) {
            revert InvalidSourceChain(
                signal.sourceChainId,
                assetChainId
            );
        }

        if (signal.sourceGateway != assetGateway) {
            revert InvalidSourceGateway(
                signal.sourceGateway,
                assetGateway
            );
        }

        if (signal.sourceMarket == address(0)) {
            revert InvalidSourceMarket();
        }

        if (!_isSupportedMarketType(signal.marketType)) {
            revert InvalidMarketType(
                signal.marketType
            );
        }

        if (signal.marketId == bytes32(0)) {
            revert InvalidMarketId();
        }

        if (signal.nonce == 0) {
            revert InvalidSignalNonce();
        }

        if (signal.timestamp == 0) {
            revert InvalidSignalTimestamp();
        }

        if (signal.callbackData.length == 0) {
            revert EmptyCallbackData();
        }

        /*
         * Solidity external function calldata contains at least four
         * bytes for the function selector.
         */
        if (signal.callbackData.length < 4) {
            revert InvalidCallbackDataLength(
                signal.callbackData.length
            );
        }
    }

    /**
     * @notice Validates a ReactiveCommand before dispatch.
     */
    function _validateCommand(
        ReactiveCommand memory command
    )
        internal
        pure
    {
        if (command.version != MESSAGE_VERSION) {
            revert InvalidMessageVersion(
                command.version,
                MESSAGE_VERSION
            );
        }

        if (command.commandId == bytes32(0)) {
            revert InvalidMarketId();
        }

        if (command.targetMarket == address(0)) {
            revert InvalidSourceMarket();
        }

        if (!_isSupportedMarketType(command.marketType)) {
            revert InvalidMarketType(
                command.marketType
            );
        }

        if (command.marketId == bytes32(0)) {
            revert InvalidMarketId();
        }

        if (command.signalNonce == 0) {
            revert InvalidSignalNonce();
        }

        if (command.callData.length == 0) {
            revert EmptyCallbackData();
        }

        if (command.callData.length < 4) {
            revert InvalidCallbackDataLength(
                command.callData.length
            );
        }
    }

    /**
     * @notice Returns whether a market type is recognized.
     */
    function _isSupportedMarketType(
        uint8 marketType
    )
        internal
        pure
        returns (bool)
    {
        return (
            marketType == MARKET_TYPE_ERC20 ||
            marketType == MARKET_TYPE_ERC1155
        );
    }

    // =============================================================
    //                      COMMAND GENERATION
    // =============================================================

    /**
     * @notice Generates a deterministic command ID.
     *
     * Every gateway signal nonce is unique, and the source chain,
     * gateway, market and payload are included to prevent collisions.
     */
    function _calculateCommandId(
        MarketSignal memory signal
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                signal.version,
                signal.sourceChainId,
                signal.sourceGateway,
                signal.sourceMarket,
                signal.marketType,
                signal.marketId,
                signal.action,
                signal.nonce,
                signal.timestamp,
                keccak256(signal.callbackData)
            )
        );
    }

    // =============================================================
    //                         VIEW FUNCTIONS
    // =============================================================

    /**
     * @notice Converts a MarketSignal envelope into a ReactiveCommand.
     *
     * This is useful for frontend previews, deployment tests and Foundry
     * unit tests.
     */
    function previewCommand(
        bytes calldata envelope
    )
        external
        view
        returns (
            MarketSignal memory signal,
            ReactiveCommand memory command,
            bytes memory commandBody
        )
    {
        signal = abi.decode(
            envelope,
            (MarketSignal)
        );

        _validateSignal(signal);

        bytes32 commandId = _calculateCommandId(signal);

        command = ReactiveCommand({
            version: MESSAGE_VERSION,
            commandId: commandId,
            targetMarket: signal.sourceMarket,
            marketType: signal.marketType,
            marketId: signal.marketId,
            action: signal.action,
            signalNonce: signal.nonce,
            callData: signal.callbackData
        });

        commandBody = abi.encode(command);
    }

    /**
     * @notice Returns the Hyperlane fee for a command.
     */
    function quoteCommand(
        ReactiveCommand calldata command
    )
        external
        view
        returns (uint256 fee)
    {
        _validateCommand(command);

        bytes memory commandBody = abi.encode(command);

        fee = mailbox.quoteDispatch(
            assetDomain,
            assetGatewayRecipient,
            commandBody
        );
    }

    /**
     * @notice Returns the Hyperlane fee for an already encoded command.
     */
    function quoteCommandBody(
        bytes calldata commandBody
    )
        external
        view
        returns (uint256 fee)
    {
        ReactiveCommand memory command = abi.decode(
            commandBody,
            (ReactiveCommand)
        );

        _validateCommand(command);

        fee = mailbox.quoteDispatch(
            assetDomain,
            assetGatewayRecipient,
            commandBody
        );
    }

    /**
     * @notice Decodes a MarketSignal envelope.
     */
    function decodeSignal(
        bytes calldata envelope
    )
        external
        pure
        returns (MarketSignal memory signal)
    {
        signal = abi.decode(
            envelope,
            (MarketSignal)
        );
    }

    /**
     * @notice Decodes a ReactiveCommand body.
     */
    function decodeCommand(
        bytes calldata commandBody
    )
        external
        pure
        returns (ReactiveCommand memory command)
    {
        command = abi.decode(
            commandBody,
            (ReactiveCommand)
        );
    }

    /**
     * @notice Encodes a MarketSignal.
     */
    function encodeSignal(
        MarketSignal calldata signal
    )
        external
        pure
        returns (bytes memory envelope)
    {
        envelope = abi.encode(signal);
    }

    /**
     * @notice Encodes a ReactiveCommand.
     */
    function encodeCommand(
        ReactiveCommand calldata command
    )
        external
        pure
        returns (bytes memory commandBody)
    {
        commandBody = abi.encode(command);
    }

    /**
     * @notice Computes the command ID for a MarketSignal.
     */
    function calculateCommandId(
        MarketSignal calldata signal
    )
        external
        pure
        returns (bytes32 commandId)
    {
        MarketSignal memory signalCopy = signal;

        commandId = _calculateCommandId(
            signalCopy
        );
    }

    /**
     * @notice Converts an EVM address into Hyperlane bytes32 format.
     */
    function addressToBytes32(
        address account
    )
        external
        pure
        returns (bytes32)
    {
        return bytes32(
            uint256(
                uint160(account)
            )
        );
    }

    /**
     * @notice Returns the selector contained in callback calldata.
     */
    function callbackSelector(
        bytes calldata callData
    )
        external
        pure
        returns (bytes4 selector)
    {
        if (callData.length < 4) {
            revert InvalidCallbackDataLength(
                callData.length
            );
        }

        assembly ("memory-safe") {
            selector := calldataload(callData.offset)
        }
    }

    // =============================================================
    //                       OWNER ADMINISTRATION
    // =============================================================

    /**
     * @notice Transfers ownership.
     */
    function transferOwnership(
        address newOwner
    )
        external
        onlyOwner
    {
        if (newOwner == address(0)) {
            revert ZeroAddress();
        }

        address previousOwner = owner;

        owner = newOwner;

        emit OwnerTransferred(
            previousOwner,
            newOwner
        );
    }

    /**
     * @notice Withdraws unused native currency.
     */
    function withdrawNative(
        address payable recipient,
        uint256 amount
    )
        external
        onlyOwner
    {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }

        (bool success, ) = recipient.call{
            value: amount
        }("");

        if (!success) {
            revert NativeTransferFailed();
        }

        emit NativeCurrencyWithdrawn(
            recipient,
            amount
        );
    }

    /**
     * @notice Withdraws the entire native-currency balance.
     */
    function withdrawAllNative(
        address payable recipient
    )
        external
        onlyOwner
    {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }

        uint256 amount = address(this).balance;

        (bool success, ) = recipient.call{
            value: amount
        }("");

        if (!success) {
            revert NativeTransferFailed();
        }

        emit NativeCurrencyWithdrawn(
            recipient,
            amount
        );
    }

    // =============================================================
    //                       NATIVE CURRENCY
    // =============================================================

    /**
     * @notice Allows the contract to receive REACT/native currency for
     * Hyperlane dispatch fees.
     */
    receive()
    external
    payable
    override(AbstractPayer, IPayer)
{
    emit NativeCurrencyReceived(
        msg.sender,
        msg.value
    );
}
}