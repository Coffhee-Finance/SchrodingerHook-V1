// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IHyperlaneMailbox
 * @notice Minimal Hyperlane Mailbox interface required by Coffhee Finance.
 */
interface IHyperlaneMailbox {
    /**
     * @notice Dispatches a message to a contract on another Hyperlane domain.
     */
    function dispatch(
        uint32 destinationDomain,
        bytes32 recipientAddress,
        bytes calldata messageBody
    ) external payable returns (bytes32 messageId);

    /**
     * @notice Returns the native-token fee required to dispatch a message.
     */
    function quoteDispatch(
        uint32 destinationDomain,
        bytes32 recipientAddress,
        bytes calldata messageBody
    ) external view returns (uint256 fee);
}