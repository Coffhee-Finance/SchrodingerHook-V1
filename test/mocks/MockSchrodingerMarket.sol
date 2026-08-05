// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title MockSchrodingerMarket
 * @notice Mock market supporting the common Reactive Network rebalance
 *         interface used by both Schrodinger market types.
 *
 * @dev This mock can represent either:
 * - an ERC-20/ERC-7984 Schrodinger market; or
 * - an ERC-1155/ERC-3475 Schrodinger market.
 *
 * The actual asset logic is irrelevant to the gateway. Both market types
 * expose the same automation callback:
 *
 * `executeReactiveRebalance(bytes32,bytes)`
 */
contract MockSchrodingerMarket {
    address public reactiveGateway;

    bytes32 public lastMarketId;
    bytes public lastRebalanceData;

    uint256 public executionCount;

    bool public shouldRevert;

    event ReactiveGatewaySet(
        address indexed gateway
    );

    event ReactiveRebalanceExecuted(
        bytes32 indexed marketId,
        bytes rebalanceData,
        uint256 executionCount
    );

    error ZeroAddress();

    error OnlyReactiveGateway(
        address caller
    );

    error ForcedRevert();

    /**
     * @notice Sets the gateway authorized to execute automated callbacks.
     */
    function setReactiveGateway(
        address gateway
    ) external {
        if (gateway == address(0)) {
            revert ZeroAddress();
        }

        reactiveGateway = gateway;

        emit ReactiveGatewaySet(
            gateway
        );
    }

    /**
     * @notice Enables or disables forced callback failure.
     *
     * @dev Useful for testing that failed commands do not remain marked as
     * processed by the gateway.
     */
    function setShouldRevert(
        bool enabled
    ) external {
        shouldRevert = enabled;
    }

    /**
     * @notice Common automated rebalancing callback used by both market types.
     *
     * @param marketId Logical identifier for the target market or pool.
     * @param rebalanceData Encoded market-specific rebalance instructions.
     */
    function executeReactiveRebalance(
        bytes32 marketId,
        bytes calldata rebalanceData
    ) external {
        if (msg.sender != reactiveGateway) {
            revert OnlyReactiveGateway(
                msg.sender
            );
        }

        if (shouldRevert) {
            revert ForcedRevert();
        }

        lastMarketId =
            marketId;

        lastRebalanceData =
            rebalanceData;

        unchecked {
            ++executionCount;
        }

        emit ReactiveRebalanceExecuted(
            marketId,
            rebalanceData,
            executionCount
        );
    }

    /**
     * @notice Deliberately unapproved function used to test the gateway's
     * function-selector whitelist.
     */
    function unapprovedFunction(
        uint256
    ) external {}

    /**
     * @notice Clears recorded execution information between tests.
     */
    function reset() external {
        lastMarketId = bytes32(0);
        lastRebalanceData = bytes("");
        executionCount = 0;
        shouldRevert = false;
    }
}