// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SchrodingerHyperlaneGateway
 * @author Coffhee Finance
 *
 * @notice
 * Asset-chain gateway shared by every Schrodinger market.
 *
 * Supported market types:
 * - ERC-20 / ERC-7984 Schrodinger markets
 * - ERC-1155 CoffheeMarketToken markets
 * - Future market adapters registered by governance
 *
 * The gateway performs two jobs:
 *
 * 1. Emits a standardized SchrodingerMarketSignal event that the Reactive
 *    Network contract subscribes to.
 *
 * 2. Receives authenticated Hyperlane messages and optionally executes
 *    approved callback selectors against registered Schrodinger markets.
 *
 * @dev
 * Hyperlane domain IDs are uint32 values. They should not automatically be
 * assumed to equal EVM chain IDs on every network.
 */
contract SchrodingerHyperlaneGateway is Ownable, ReentrancyGuard {
    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint8 public constant MESSAGE_VERSION = 1;

    uint8 public constant MARKET_TYPE_ERC20 = 1;
    uint8 public constant MARKET_TYPE_ERC1155 = 2;

    // ---------------------------------------------------------------------
    // Structs
    // ---------------------------------------------------------------------

    struct MarketConfig {
        bool registered;
        bool active;
        uint8 marketType;
    }

    /**
     * @notice Standard event envelope observed by Reactive Network.
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
     * @notice Message returned through Hyperlane.
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

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Hyperlane Mailbox deployed on the asset chain.
    address public immutable mailbox;

    /// @notice Hyperlane domain from which Reactive messages are accepted.
    uint32 public trustedReactiveDomain;

    /// @notice Reactive contract encoded as a Hyperlane bytes32 address.
    bytes32 public trustedReactiveSender;

    /// @notice Incrementing identifier for outgoing market signals.
    uint256 public signalNonce;

    /// @notice Registered Schrodinger market configuration.
    mapping(address market => MarketConfig config) public markets;

    /// @notice Optional operators allowed to publish for registered markets.
    mapping(address operator => bool approved) public signalOperators;

    /**
     * @notice Selectors that Reactive Network is allowed to call.
     *
     * market => function selector => allowed
     */
    mapping(address market => mapping(bytes4 selector => bool allowed))
        public allowedSelectors;

    /// @notice Prevents a Hyperlane command from executing twice.
    mapping(bytes32 commandId => bool processed) public processedCommands;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /**
     * @notice Event subscribed to by SchrodingerReactive.
     *
     * The entire message is encoded in one unindexed bytes value so the
     * Reactive contract can recover it directly from LogRecord.data.
     */
    event SchrodingerMarketSignal(bytes envelope);

    event MarketRegistered(
        address indexed market,
        uint8 indexed marketType
    );

    event MarketStatusUpdated(
        address indexed market,
        bool active
    );

    event SignalOperatorUpdated(
        address indexed operator,
        bool approved
    );

    event SelectorPermissionUpdated(
        address indexed market,
        bytes4 indexed selector,
        bool allowed
    );

    event TrustedReactiveEndpointUpdated(
        uint32 indexed reactiveDomain,
        bytes32 indexed reactiveSender
    );

    event ReactiveCommandExecuted(
        bytes32 indexed commandId,
        address indexed targetMarket,
        uint8 indexed action,
        bytes returnData
    );

    event ReactiveCommandFailed(
        bytes32 indexed commandId,
        address indexed targetMarket,
        bytes reason
    );

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error InvalidMarketType(uint8 marketType);
    error MarketNotRegistered(address market);
    error MarketNotActive(address market);
    error UnauthorizedPublisher(address caller, address market);
    error OnlyMailbox(address caller);
    error InvalidReactiveDomain(uint32 received, uint32 expected);
    error InvalidReactiveSender(bytes32 received, bytes32 expected);
    error UnsupportedMessageVersion(uint8 version);
    error CommandAlreadyProcessed(bytes32 commandId);
    error EmptyCallData();
    error SelectorNotAllowed(address market, bytes4 selector);
    error MarketTypeMismatch(uint8 received, uint8 expected);
    error ExternalCallFailed(bytes reason);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(
        address initialOwner,
        address mailbox_,
        uint32 trustedReactiveDomain_,
        bytes32 trustedReactiveSender_
    ) Ownable(initialOwner) {
        if (mailbox_ == address(0)) {
            revert ZeroAddress();
        }

        mailbox = mailbox_;
        trustedReactiveDomain = trustedReactiveDomain_;
        trustedReactiveSender = trustedReactiveSender_;
    }

    // ---------------------------------------------------------------------
    // Administration
    // ---------------------------------------------------------------------

    /**
     * @notice Registers either Schrodinger market implementation.
     */
    function registerMarket(
        address market,
        uint8 marketType
    ) external onlyOwner {
        if (market == address(0)) {
            revert ZeroAddress();
        }

        if (
            marketType != MARKET_TYPE_ERC20 &&
            marketType != MARKET_TYPE_ERC1155
        ) {
            revert InvalidMarketType(marketType);
        }

        markets[market] = MarketConfig({
            registered: true,
            active: true,
            marketType: marketType
        });

        emit MarketRegistered(market, marketType);
    }

    function setMarketActive(
        address market,
        bool active
    ) external onlyOwner {
        if (!markets[market].registered) {
            revert MarketNotRegistered(market);
        }

        markets[market].active = active;

        emit MarketStatusUpdated(market, active);
    }

    function setSignalOperator(
        address operator,
        bool approved
    ) external onlyOwner {
        if (operator == address(0)) {
            revert ZeroAddress();
        }

        signalOperators[operator] = approved;

        emit SignalOperatorUpdated(operator, approved);
    }

    /**
     * @notice Whitelists a function that Reactive Network may execute.
     *
     * Examples might include:
     *
     * - pauseMarket(bytes32)
     * - updateRiskState(bytes32,uint256)
     * - executeReactiveRebalance(bytes32,bytes)
     * - setPositionStatus(uint256,uint256,uint8)
     */
    function setAllowedSelector(
        address market,
        bytes4 selector,
        bool allowed
    ) external onlyOwner {
        if (!markets[market].registered) {
            revert MarketNotRegistered(market);
        }

        allowedSelectors[market][selector] = allowed;

        emit SelectorPermissionUpdated(market, selector, allowed);
    }

    function setTrustedReactiveEndpoint(
        uint32 reactiveDomain,
        bytes32 reactiveSender
    ) external onlyOwner {
        trustedReactiveDomain = reactiveDomain;
        trustedReactiveSender = reactiveSender;

        emit TrustedReactiveEndpointUpdated(
            reactiveDomain,
            reactiveSender
        );
    }

    // ---------------------------------------------------------------------
    // Outgoing market signals
    // ---------------------------------------------------------------------

    /**
     * @notice Publishes a signal for the caller's own registered market.
     */
    function publishSignal(
        bytes32 marketId,
        uint8 action,
        bytes calldata callbackData
    ) external returns (uint256 nonce, bytes memory envelope) {
        return _publishSignal(
            msg.sender,
            marketId,
            action,
            callbackData
        );
    }

    /**
     * @notice Publishes a signal on behalf of a registered market.
     *
     * @dev Useful during initial integration if the current hooks cannot yet
     * call publishSignal directly.
     */
    function publishSignalFor(
        address market,
        bytes32 marketId,
        uint8 action,
        bytes calldata callbackData
    ) external returns (uint256 nonce, bytes memory envelope) {
        if (
            msg.sender != owner() &&
            !signalOperators[msg.sender] &&
            msg.sender != market
        ) {
            revert UnauthorizedPublisher(msg.sender, market);
        }

        return _publishSignal(
            market,
            marketId,
            action,
            callbackData
        );
    }

    function _publishSignal(
        address market,
        bytes32 marketId,
        uint8 action,
        bytes calldata callbackData
    ) internal returns (uint256 nonce, bytes memory envelope) {
        MarketConfig memory config = markets[market];

        if (!config.registered) {
            revert MarketNotRegistered(market);
        }

        if (!config.active) {
            revert MarketNotActive(market);
        }

        unchecked {
            nonce = ++signalNonce;
        }

        MarketSignal memory signal = MarketSignal({
            version: MESSAGE_VERSION,
            sourceChainId: block.chainid,
            sourceGateway: address(this),
            sourceMarket: market,
            marketType: config.marketType,
            marketId: marketId,
            action: action,
            nonce: nonce,
            timestamp: block.timestamp,
            callbackData: callbackData
        });

        envelope = abi.encode(signal);

        emit SchrodingerMarketSignal(envelope);
    }

    // ---------------------------------------------------------------------
    // Hyperlane receiver
    // ---------------------------------------------------------------------

    /**
     * @notice Receives a command from the trusted Reactive contract.
     *
     * @dev Hyperlane Mailbox invokes this function after message delivery.
     */
    function handle(
        uint32 originDomain,
        bytes32 sender,
        bytes calldata body
    ) external payable nonReentrant {
        if (msg.sender != mailbox) {
            revert OnlyMailbox(msg.sender);
        }

        if (originDomain != trustedReactiveDomain) {
            revert InvalidReactiveDomain(
                originDomain,
                trustedReactiveDomain
            );
        }

        if (sender != trustedReactiveSender) {
            revert InvalidReactiveSender(
                sender,
                trustedReactiveSender
            );
        }

        ReactiveCommand memory command = abi.decode(
            body,
            (ReactiveCommand)
        );

        _executeReactiveCommand(command);
    }

    function _executeReactiveCommand(
        ReactiveCommand memory command
    ) internal {
        if (command.version != MESSAGE_VERSION) {
            revert UnsupportedMessageVersion(command.version);
        }

        if (processedCommands[command.commandId]) {
            revert CommandAlreadyProcessed(command.commandId);
        }

        MarketConfig memory config = markets[command.targetMarket];

        if (!config.registered) {
            revert MarketNotRegistered(command.targetMarket);
        }

        if (!config.active) {
            revert MarketNotActive(command.targetMarket);
        }

        if (config.marketType != command.marketType) {
            revert MarketTypeMismatch(
                command.marketType,
                config.marketType
            );
        }

        if (command.callData.length < 4) {
            revert EmptyCallData();
        }

        bytes4 selector = _selector(command.callData);

        if (!allowedSelectors[command.targetMarket][selector]) {
            revert SelectorNotAllowed(
                command.targetMarket,
                selector
            );
        }

        /*
         * Mark before the external call. A revert rolls this write back.
         */
        processedCommands[command.commandId] = true;

        (bool success, bytes memory returnData) =
            command.targetMarket.call(command.callData);

        if (!success) {
            emit ReactiveCommandFailed(
                command.commandId,
                command.targetMarket,
                returnData
            );

            revert ExternalCallFailed(returnData);
        }

        emit ReactiveCommandExecuted(
            command.commandId,
            command.targetMarket,
            command.action,
            returnData
        );
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function isRegisteredMarket(
        address market
    ) external view returns (bool) {
        return markets[market].registered;
    }

    function encodeSignal(
        MarketSignal calldata signal
    ) external pure returns (bytes memory) {
        return abi.encode(signal);
    }

    function decodeSignal(
        bytes calldata envelope
    ) external pure returns (MarketSignal memory) {
        return abi.decode(envelope, (MarketSignal));
    }

    function encodeCommand(
        ReactiveCommand calldata command
    ) external pure returns (bytes memory) {
        return abi.encode(command);
    }

    function decodeCommand(
        bytes calldata body
    ) external pure returns (ReactiveCommand memory) {
        return abi.decode(body, (ReactiveCommand));
    }

    function addressToBytes32(
        address account
    ) external pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function _selector(
        bytes memory callData
    ) internal pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := mload(add(callData, 0x20))
        }
    }
}