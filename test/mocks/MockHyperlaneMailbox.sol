// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    IHyperlaneMailbox
} from "../../src/reactive/interfaces/IHyperlaneMailbox.sol";

/**
 * @title MockHyperlaneMailbox
 * @notice Minimal Hyperlane Mailbox mock used by the Schrodinger gateway and
 *         Reactive Network tests.
 *
 * @dev The mock:
 * - returns a configurable dispatch fee;
 * - records dispatched message information;
 * - generates deterministic mock message IDs;
 * - simulates Hyperlane delivery to a destination `handle()` function.
 */
contract MockHyperlaneMailbox is IHyperlaneMailbox {
    uint256 public quotedFee;

    uint32 public lastDestinationDomain;
    bytes32 public lastRecipient;
    bytes public lastBody;
    uint256 public lastValue;
    bytes32 public lastMessageId;

    uint256 public dispatchCount;

    event MockDispatch(
        bytes32 indexed messageId,
        uint32 indexed destinationDomain,
        bytes32 indexed recipient,
        uint256 value,
        bytes body
    );

    event MockDelivery(
        address indexed recipient,
        uint32 indexed originDomain,
        bytes32 indexed sender,
        bytes body
    );

    /**
     * @notice Configures the fee returned by `quoteDispatch`.
     */
    function setQuotedFee(
        uint256 newFee
    ) external {
        quotedFee = newFee;
    }

    /**
     * @inheritdoc IHyperlaneMailbox
     */
    function quoteDispatch(
        uint32,
        bytes32,
        bytes calldata
    )
        external
        view
        override
        returns (uint256 fee)
    {
        fee = quotedFee;
    }

    /**
     * @inheritdoc IHyperlaneMailbox
     */
    function dispatch(
        uint32 destinationDomain,
        bytes32 recipientAddress,
        bytes calldata messageBody
    )
        external
        payable
        override
        returns (bytes32 messageId)
    {
        lastDestinationDomain =
            destinationDomain;

        lastRecipient =
            recipientAddress;

        lastBody =
            messageBody;

        lastValue =
            msg.value;

        unchecked {
            ++dispatchCount;
        }

        messageId = keccak256(
            abi.encode(
                address(this),
                msg.sender,
                destinationDomain,
                recipientAddress,
                messageBody,
                msg.value,
                dispatchCount
            )
        );

        lastMessageId =
            messageId;

        emit MockDispatch(
            messageId,
            destinationDomain,
            recipientAddress,
            msg.value,
            messageBody
        );
    }

    /**
     * @notice Simulates Hyperlane delivering a message to a recipient.
     *
     * @dev The destination must expose:
     *
     * `handle(uint32 originDomain, bytes32 sender, bytes body)`
     *
     * Since this contract performs the external call, the receiving gateway
     * sees `msg.sender == address(this)`, matching its configured mailbox.
     */
    function deliver(
        address recipient,
        uint32 originDomain,
        bytes32 sender,
        bytes calldata body
    ) external {
        emit MockDelivery(
            recipient,
            originDomain,
            sender,
            body
        );

        (bool success, bytes memory reason) =
            recipient.call(
                abi.encodeWithSignature(
                    "handle(uint32,bytes32,bytes)",
                    originDomain,
                    sender,
                    body
                )
            );

        if (!success) {
            assembly ("memory-safe") {
                revert(
                    add(reason, 0x20),
                    mload(reason)
                )
            }
        }
    }

    /**
     * @notice Clears the recorded dispatch data between tests.
     */
    function reset() external {
        lastDestinationDomain = 0;
        lastRecipient = bytes32(0);
        lastBody = bytes("");
        lastValue = 0;
        lastMessageId = bytes32(0);
        dispatchCount = 0;
    }
}