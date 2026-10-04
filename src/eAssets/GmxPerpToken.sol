// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title GmxPerpToken
 * @author Coffhee Finance
 *
 * @notice
 * Open House prototype demonstrating a tokenized GMX perpetual
 * position wrapped as a confidential Coffhee ePerp.
 *
 * Architecture:
 *
 *             GMX Perpetual Position
 *                       |
 *                GMX SDK / API
 *                       |
 *                       v
 *               GmxPerpPosition3475
 *              ERC-3475-style position
 *                       |
 *                       | lock
 *                       v
 *                    ePerp
 *              ERC-1155 Coffhee wrapper
 *                       |
 *              Fhenix CoFHE metadata
 *                       |
 *              Tellor market data
 *                       |
 *                       v
 *               SchrodingerHook
 *
 *
 * IMPORTANT:
 *
 * This prototype does NOT itself open a GMX position.
 *
 * GmxPerpPosition3475 represents a GMX position that has been
 * verified by the Coffhee GMX integration layer.
 *
 * The next implementation stage will connect:
 *
 *      GMX SDK/API
 *            +
 *      GMX Reader
 *            +
 *      GMX ExchangeRouter
 *
 * to the mint/burn lifecycle.
 */

import {ERC1155} from
    "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

import {ERC1155Holder} from
    "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {Ownable} from
    "@openzeppelin/contracts/access/Ownable.sol";

import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/*
 * Fhenix CoFHE.
 *
 * Pin the exact CoFHE package version before deployment because
 * encrypted type / ACL APIs may differ between releases.
 */
import {
    FHE,
    euint64,
    InEuint64
} from
    "@fhenixprotocol/cofhe-contracts/FHE.sol";


/*//////////////////////////////////////////////////////////////
                        TELLOR INTERFACE
//////////////////////////////////////////////////////////////*/

/**
 * @notice
 * Minimal Tellor interface used by Coffhee.
 *
 * Tellor remains the independent Coffhee oracle layer.
 *
 * Potential queries:
 *
 * - ETH/USD
 * - BTC/USD
 * - collateral asset/USD
 * - funding/reference data
 * - volatility/risk information
 * - other external data required by Schrodinger
 */
interface ITellorPerpOracle {

    function getDataBefore(
        bytes32 queryId,
        uint256 timestamp
    )
        external
        view
        returns (
            bool ifRetrieve,
            bytes memory value,
            uint256 timestampRetrieved
        );
}


/*//////////////////////////////////////////////////////////////
                 MOCK ERC-3475 GMX POSITION
//////////////////////////////////////////////////////////////*/

/**
 * @title GmxPerpPosition3475
 *
 * @notice
 * Simplified ERC-3475-style representation of a GMX perpetual
 * position.
 *
 * CLASS:
 *      GMX perpetual market
 *
 * NONCE:
 *      individual tokenized position / position series
 *
 *
 * Example:
 *
 * CLASS 1:
 *      GMX ETH/USD Perpetual
 *
 * NONCE 1:
 *      Coffhee GMX ETH Long Position
 *
 *
 * The Open House prototype uses one ETH/USD long position.
 *
 * Later the GMX SDK/API will supply / verify the actual GMX
 * position information.
 */

contract GmxPerpPosition3475 is Ownable {

    /*//////////////////////////////////////////////////////////////
                            STRUCTURES
    //////////////////////////////////////////////////////////////*/

    struct Transaction {

        uint256 classId;

        uint256 nonceId;

        uint256 amount;
    }


    /**
     * @notice
     * PUBLIC description of the tokenized GMX position.
     *
     * We intentionally do not put sensitive holder-specific
     * information here.
     */
    struct PositionData {

        string venue;

        string market;

        string collateralAsset;

        string settlementAsset;

        string positionType;

        uint256 chainId;

        address gmxMarket;

        bytes32 gmxPositionKey;

        bool active;
    }


    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /**
     * CLASS 1 = GMX ETH/USD perpetual.
     */
    uint256 public constant CLASS_ID = 1;

    /**
     * NONCE 1 = prototype Coffhee position series.
     */
    uint256 public constant NONCE_ID = 1;


    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    PositionData private _position;

    mapping(
        address =>
        mapping(uint256 =>
        mapping(uint256 => uint256))
    )
        private _balances;


    mapping(
        address =>
        mapping(address => bool)
    )
        private _operators;


    uint256 public totalIssued;


    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event PositionIssued(
        address indexed to,
        uint256 indexed classId,
        uint256 indexed nonceId,
        uint256 amount
    );


    event PositionTransferred(
        address indexed from,
        address indexed to,
        uint256 indexed classId,
        uint256 nonceId,
        uint256 amount
    );


    event PositionRedeemed(
        address indexed from,
        uint256 indexed classId,
        uint256 indexed nonceId,
        uint256 amount
    );


    event OperatorApproval(
        address indexed owner,
        address indexed operator,
        bool approved
    );


    event GMXPositionUpdated(
        address indexed gmxMarket,
        bytes32 indexed positionKey,
        bool active
    );


    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidPosition();

    error ZeroAddress();

    error ZeroAmount();

    error InsufficientBalance();

    error Unauthorized();


    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param initialOwner
     * Coffhee controller / deployer.
     *
     * @param gmxMarket_
     * GMX market address.
     *
     * For the initial mock deployment this may be address(0)
     * until the real GMX integration is configured.
     *
     * @param positionKey_
     * GMX position key.
     *
     * This will later correspond to the position identifier
     * retrieved/generated through GMX.
     */
    constructor(
        address initialOwner,
        address gmxMarket_,
        bytes32 positionKey_
    )
        Ownable(initialOwner)
    {
        _position = PositionData({

            venue:
                "GMX",

            market:
                "ETH/USD",

            collateralAsset:
                "USDC",

            settlementAsset:
                "USD",

            positionType:
                "LONG",

            chainId:
                block.chainid,

            gmxMarket:
                gmxMarket_,

            gmxPositionKey:
                positionKey_,

            active:
                true
        });
    }


    /*//////////////////////////////////////////////////////////////
                       POSITION INFORMATION
    //////////////////////////////////////////////////////////////*/

    function positionData()
        external
        view
        returns (PositionData memory)
    {
        return _position;
    }


    function classId()
        external
        pure
        returns (uint256)
    {
        return CLASS_ID;
    }


    function nonceId()
        external
        pure
        returns (uint256)
    {
        return NONCE_ID;
    }


    /*//////////////////////////////////////////////////////////////
                         POSITION BALANCE
    //////////////////////////////////////////////////////////////*/

    function balanceOf(
        address account,
        uint256 classId_,
        uint256 nonceId_
    )
        public
        view
        returns (uint256)
    {
        return
            _balances[account]
                [classId_]
                [nonceId_];
    }


    /*//////////////////////////////////////////////////////////////
                       POSITION TOKENIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Mint the ERC-3475 representation of verified GMX exposure.
     *
     * OPEN HOUSE:
     *
     * Owner manually performs verification.
     *
     * PRODUCTION:
     *
     * This should only execute after Coffhee verifies that the
     * corresponding GMX position has actually been executed.
     */
    function issuePosition(
        address to,
        Transaction[] calldata transactions
    )
        external
        onlyOwner
    {
        if (to == address(0)) {
            revert ZeroAddress();
        }

        uint256 length =
            transactions.length;

        for (
            uint256 i = 0;
            i < length;
            ++i
        ) {

            Transaction calldata txn =
                transactions[i];

            _validatePosition(
                txn.classId,
                txn.nonceId
            );

            if (txn.amount == 0) {
                revert ZeroAmount();
            }

            _balances[to]
                [txn.classId]
                [txn.nonceId]
                += txn.amount;

            totalIssued +=
                txn.amount;

            emit PositionIssued(
                to,
                txn.classId,
                txn.nonceId,
                txn.amount
            );
        }
    }


    /*//////////////////////////////////////////////////////////////
                         POSITION TRANSFER
    //////////////////////////////////////////////////////////////*/

    function transferFrom(
        address from,
        address to,
        Transaction[] calldata transactions
    )
        external
    {
        if (
            msg.sender != from &&
            !_operators[from][msg.sender]
        ) {
            revert Unauthorized();
        }

        if (to == address(0)) {
            revert ZeroAddress();
        }

        uint256 length =
            transactions.length;

        for (
            uint256 i = 0;
            i < length;
            ++i
        ) {

            Transaction calldata txn =
                transactions[i];

            _validatePosition(
                txn.classId,
                txn.nonceId
            );

            uint256 currentBalance =
                _balances[from]
                    [txn.classId]
                    [txn.nonceId];

            if (
                currentBalance <
                txn.amount
            ) {
                revert InsufficientBalance();
            }

            unchecked {

                _balances[from]
                    [txn.classId]
                    [txn.nonceId]
                    =
                    currentBalance -
                    txn.amount;
            }

            _balances[to]
                [txn.classId]
                [txn.nonceId]
                += txn.amount;

            emit PositionTransferred(
                from,
                to,
                txn.classId,
                txn.nonceId,
                txn.amount
            );
        }
    }


    /*//////////////////////////////////////////////////////////////
                           APPROVAL
    //////////////////////////////////////////////////////////////*/

    function setApprovalFor(
        address operator,
        bool approved
    )
        external
    {
        _operators[msg.sender][operator] =
            approved;

        emit OperatorApproval(
            msg.sender,
            operator,
            approved
        );
    }


    function isApprovedFor(
        address owner_,
        address operator
    )
        external
        view
        returns (bool)
    {
        return
            _operators[owner_][operator];
    }


    /*//////////////////////////////////////////////////////////////
                     POSITION REDEMPTION / BURN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Burns tokenized position units.
     *
     * Later this should correspond to confirmed GMX position
     * reduction / closure.
     */
    function redeemPosition(
        address from,
        Transaction[] calldata transactions
    )
        external
        onlyOwner
    {
        uint256 length =
            transactions.length;

        for (
            uint256 i = 0;
            i < length;
            ++i
        ) {

            Transaction calldata txn =
                transactions[i];

            _validatePosition(
                txn.classId,
                txn.nonceId
            );

            uint256 currentBalance =
                _balances[from]
                    [txn.classId]
                    [txn.nonceId];

            if (
                currentBalance <
                txn.amount
            ) {
                revert InsufficientBalance();
            }

            unchecked {

                _balances[from]
                    [txn.classId]
                    [txn.nonceId]
                    =
                    currentBalance -
                    txn.amount;

                totalIssued -=
                    txn.amount;
            }

            emit PositionRedeemed(
                from,
                txn.classId,
                txn.nonceId,
                txn.amount
            );
        }
    }


    /*//////////////////////////////////////////////////////////////
                       GMX POSITION REFERENCE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Update the real GMX identifiers after SDK/API integration.
     *
     * In production this should be controlled by the Coffhee
     * GMX adapter rather than an EOA.
     */
    function setGMXPosition(
        address gmxMarket_,
        bytes32 positionKey_,
        bool active_
    )
        external
        onlyOwner
    {
        _position.gmxMarket =
            gmxMarket_;

        _position.gmxPositionKey =
            positionKey_;

        _position.active =
            active_;

        emit GMXPositionUpdated(
            gmxMarket_,
            positionKey_,
            active_
        );
    }


    /*//////////////////////////////////////////////////////////////
                            INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _validatePosition(
        uint256 classId_,
        uint256 nonceId_
    )
        internal
        pure
    {
        if (
            classId_ != CLASS_ID ||
            nonceId_ != NONCE_ID
        ) {
            revert InvalidPosition();
        }
    }
}


/*//////////////////////////////////////////////////////////////
                     COFFHEE ePERP
//////////////////////////////////////////////////////////////*/

/**
 * @title ePerp
 *
 * @notice
 * Coffhee ERC-1155 wrapper for the tokenized GMX perpetual
 * position.
 *
 *
 * GMX POSITION
 *
 *      |
 *      v
 *
 * ERC-3475 POSITION
 *
 *      |
 *      | lock
 *      v
 *
 * ERC-1155 ePERP
 *
 *      |
 *      +---- encrypted strategy
 *      |
 *      +---- Tellor market data
 *      |
 *      v
 *
 * SCHRODINGER HOOK
 *
 *
 * PUBLIC DATA
 * -----------
 *
 * GMX
 * ETH/USD market
 * Long / short
 * underlying market
 * position reference
 *
 *
 * CONFIDENTIAL DATA
 * -----------------
 *
 * Position size
 * Collateral exposure
 * Entry exposure
 * Target leverage
 * Rebalance threshold
 * Target allocation
 * Strategy parameters
 *
 *
 * The public GMX position itself may still be visible.
 *
 * Coffhee confidentiality applies to the ePerp holder's
 * Coffhee-level ownership and strategy information.
 *
 * A pooled GMX vault can later prevent direct 1:1 public
 * association between each ePerp holder and GMX position.
 */
contract ePerp is
    ERC1155,
    ERC1155Holder,
    Ownable,
    ReentrancyGuard
{

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant EPERP_ID = 1;


    /*//////////////////////////////////////////////////////////////
                      UNDERLYING ERC-3475
    //////////////////////////////////////////////////////////////*/

    GmxPerpPosition3475
        public immutable underlyingPosition;

    uint256
        public immutable underlyingClassId;

    uint256
        public immutable underlyingNonceId;


    /*//////////////////////////////////////////////////////////////
                       SCHRODINGER HOOK
    //////////////////////////////////////////////////////////////*/

    address public schrodingerHook;


    /*//////////////////////////////////////////////////////////////
                            TELLOR
    //////////////////////////////////////////////////////////////*/

    ITellorPerpOracle public tellor;

    /**
     * Primary market price query.
     *
     * Example:
     *
     * ETH/USD
     */
    bytes32 public marketPriceQueryId;


    /**
     * Optional collateral price query.
     *
     * Example:
     *
     * USDC/USD
     */
    bytes32 public collateralPriceQueryId;


    /**
     * Maximum age Coffhee accepts for Tellor data.
     */
    uint256 public maxOracleAge =
        30 minutes;


    /*//////////////////////////////////////////////////////////////
                     CONFIDENTIAL POSITION DATA
    //////////////////////////////////////////////////////////////*/

    /**
     * Encrypted Coffhee-level position size.
     */
    mapping(address => euint64)
        private _encryptedPositionSize;


    /**
     * Encrypted collateral exposure.
     */
    mapping(address => euint64)
        private _encryptedCollateral;


    /**
     * Encrypted entry exposure / cost basis.
     */
    mapping(address => euint64)
        private _encryptedEntryPrice;


    /**
     * Encrypted target leverage.
     *
     * Example:
     *
     * 300 = 3.00x
     */
    mapping(address => euint64)
        private _encryptedTargetLeverage;


    /**
     * Encrypted target portfolio allocation.
     *
     * Example:
     *
     * 2500 = 25.00%
     */
    mapping(address => euint64)
        private _encryptedTargetAllocationBps;


    /**
     * Encrypted rebalance threshold.
     *
     * Example:
     *
     * 500 = 5.00%
     */
    mapping(address => euint64)
        private _encryptedRebalanceThresholdBps;


    /**
     * Additional private strategy parameter.
     *
     * Could later represent:
     *
     * - maximum leverage
     * - stop-loss threshold
     * - take-profit threshold
     * - hedge ratio
     * - volatility threshold
     */
    mapping(address => euint64)
        private _encryptedStrategyParameter;


    /*//////////////////////////////////////////////////////////////
                        WRAPPER ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    uint256 public totalUnderlyingLocked;


    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event PositionWrapped(
        address indexed holder,
        uint256 underlyingAmount,
        uint256 ePerpAmount
    );


    event PositionUnwrapped(
        address indexed holder,
        uint256 ePerpAmount,
        uint256 underlyingAmount
    );


    event PrivatePositionUpdated(
        address indexed holder
    );


    event SchrodingerHookUpdated(
        address indexed hook
    );


    event TellorUpdated(
        address indexed tellor
    );


    event OracleQueriesUpdated(
        bytes32 indexed marketQuery,
        bytes32 indexed collateralQuery
    );


    event MaxOracleAgeUpdated(
        uint256 maxOracleAge
    );


    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();

    error ZeroAmount();

    error InsufficientEPerp();

    error UnderlyingTransferFailed();

    error OracleDataUnavailable();

    error StaleOracleData();


    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address initialOwner,
        address underlyingPosition_,
        address tellor_,
        bytes32 marketPriceQueryId_,
        bytes32 collateralPriceQueryId_,
        string memory metadataURI
    )
        ERC1155(metadataURI)
        Ownable(initialOwner)
    {
        if (
            initialOwner == address(0) ||
            underlyingPosition_ == address(0) ||
            tellor_ == address(0)
        ) {
            revert ZeroAddress();
        }

        underlyingPosition =
            GmxPerpPosition3475(
                underlyingPosition_
            );

        underlyingClassId =
            GmxPerpPosition3475(
                underlyingPosition_
            ).CLASS_ID();

        underlyingNonceId =
            GmxPerpPosition3475(
                underlyingPosition_
            ).NONCE_ID();

        tellor =
            ITellorPerpOracle(
                tellor_
            );

        marketPriceQueryId =
            marketPriceQueryId_;

        collateralPriceQueryId =
            collateralPriceQueryId_;
    }


    /*//////////////////////////////////////////////////////////////
                    ERC-3475 -> ERC-1155 WRAP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Lock tokenized GMX position units and mint ePerp.
     *
     * Before wrapping:
     *
     * underlyingPosition.setApprovalFor(
     *     address(ePerp),
     *     true
     * );
     *
     * Prototype ratio:
     *
     * 1 ERC-3475 position unit
     * =
     * 1 ERC-1155 ePerp unit
     */
    function wrap(
        uint256 amount
    )
        external
        nonReentrant
    {
        if (amount == 0) {
            revert ZeroAmount();
        }

        uint256 balanceBefore =
            underlyingPosition.balanceOf(
                address(this),
                underlyingClassId,
                underlyingNonceId
            );

        GmxPerpPosition3475.Transaction[]
            memory transactions =
                new GmxPerpPosition3475.Transaction[](1);

        transactions[0] =
            GmxPerpPosition3475.Transaction({

                classId:
                    underlyingClassId,

                nonceId:
                    underlyingNonceId,

                amount:
                    amount
            });

        underlyingPosition.transferFrom(
            msg.sender,
            address(this),
            transactions
        );

        uint256 balanceAfter =
            underlyingPosition.balanceOf(
                address(this),
                underlyingClassId,
                underlyingNonceId
            );

        if (
            balanceAfter !=
            balanceBefore + amount
        ) {
            revert UnderlyingTransferFailed();
        }

        totalUnderlyingLocked +=
            amount;

        _mint(
            msg.sender,
            EPERP_ID,
            amount,
            ""
        );

        emit PositionWrapped(
            msg.sender,
            amount,
            amount
        );
    }


    /*//////////////////////////////////////////////////////////////
                    ERC-1155 -> ERC-3475 UNWRAP
    //////////////////////////////////////////////////////////////*/

    function unwrap(
        uint256 amount
    )
        external
        nonReentrant
    {
        if (amount == 0) {
            revert ZeroAmount();
        }

        if (
            balanceOf(
                msg.sender,
                EPERP_ID
            ) < amount
        ) {
            revert InsufficientEPerp();
        }

        _burn(
            msg.sender,
            EPERP_ID,
            amount
        );

        totalUnderlyingLocked -=
            amount;

        GmxPerpPosition3475.Transaction[]
            memory transactions =
                new GmxPerpPosition3475.Transaction[](1);

        transactions[0] =
            GmxPerpPosition3475.Transaction({

                classId:
                    underlyingClassId,

                nonceId:
                    underlyingNonceId,

                amount:
                    amount
            });

        underlyingPosition.transferFrom(
            address(this),
            msg.sender,
            transactions
        );

        emit PositionUnwrapped(
            msg.sender,
            amount,
            amount
        );
    }


    /*//////////////////////////////////////////////////////////////
                 CONFIDENTIAL POSITION / STRATEGY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Store encrypted ePerp information.
     *
     * All inputs are encrypted client-side using Fhenix CoFHE.
     *
     * The plaintext values never need to be passed as normal
     * Solidity uint256 parameters.
     */
    function setPrivatePosition(
        InEuint64 calldata positionSize,
        InEuint64 calldata collateral,
        InEuint64 calldata entryPrice,
        InEuint64 calldata targetLeverage,
        InEuint64 calldata targetAllocationBps,
        InEuint64 calldata rebalanceThresholdBps,
        InEuint64 calldata strategyParameter
    )
        external
    {
        if (
            balanceOf(
                msg.sender,
                EPERP_ID
            ) == 0
        ) {
            revert InsufficientEPerp();
        }

        _encryptedPositionSize[
            msg.sender
        ] =
            FHE.asEuint64(
                positionSize
            );

        _encryptedCollateral[
            msg.sender
        ] =
            FHE.asEuint64(
                collateral
            );

        _encryptedEntryPrice[
            msg.sender
        ] =
            FHE.asEuint64(
                entryPrice
            );

        _encryptedTargetLeverage[
            msg.sender
        ] =
            FHE.asEuint64(
                targetLeverage
            );

        _encryptedTargetAllocationBps[
            msg.sender
        ] =
            FHE.asEuint64(
                targetAllocationBps
            );

        _encryptedRebalanceThresholdBps[
            msg.sender
        ] =
            FHE.asEuint64(
                rebalanceThresholdBps
            );

        _encryptedStrategyParameter[
            msg.sender
        ] =
            FHE.asEuint64(
                strategyParameter
            );


        /*
         * Give the holder access to their own encrypted values.
         */

        FHE.allow(
            _encryptedPositionSize[msg.sender],
            msg.sender
        );

        FHE.allow(
            _encryptedCollateral[msg.sender],
            msg.sender
        );

        FHE.allow(
            _encryptedEntryPrice[msg.sender],
            msg.sender
        );

        FHE.allow(
            _encryptedTargetLeverage[msg.sender],
            msg.sender
        );

        FHE.allow(
            _encryptedTargetAllocationBps[msg.sender],
            msg.sender
        );

        FHE.allow(
            _encryptedRebalanceThresholdBps[msg.sender],
            msg.sender
        );

        FHE.allow(
            _encryptedStrategyParameter[msg.sender],
            msg.sender
        );


        /*
         * Give this contract permission to continue performing
         * FHE operations against the ciphertexts.
         */

        FHE.allowThis(
            _encryptedPositionSize[msg.sender]
        );

        FHE.allowThis(
            _encryptedCollateral[msg.sender]
        );

        FHE.allowThis(
            _encryptedEntryPrice[msg.sender]
        );

        FHE.allowThis(
            _encryptedTargetLeverage[msg.sender]
        );

        FHE.allowThis(
            _encryptedTargetAllocationBps[msg.sender]
        );

        FHE.allowThis(
            _encryptedRebalanceThresholdBps[msg.sender]
        );

        FHE.allowThis(
            _encryptedStrategyParameter[msg.sender]
        );

        emit PrivatePositionUpdated(
            msg.sender
        );
    }


    /*//////////////////////////////////////////////////////////////
                  PRIVATE REBALANCING PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Returns an encrypted target + rebalance threshold.
     *
     * This demonstrates the value that can eventually be consumed
     * by the Schrodinger rebalancing controller.
     *
     * Neither value is revealed publicly.
     */
    function encryptedRebalanceBoundary(
        address holder
    )
        external
        view
        returns (euint64)
    {
        return
            FHE.add(
                _encryptedTargetAllocationBps[
                    holder
                ],
                _encryptedRebalanceThresholdBps[
                    holder
                ]
            );
    }


    /**
     * @notice
     * Encrypted leverage target.
     *
     * This remains ciphertext.
     */
    function encryptedLeverageTarget(
        address holder
    )
        external
        view
        returns (euint64)
    {
        return
            _encryptedTargetLeverage[
                holder
            ];
    }


    /*//////////////////////////////////////////////////////////////
                         TELLOR ORACLE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Generic Tellor query.
     *
     * Includes freshness validation.
     */
    function _getTellorData(
        bytes32 queryId
    )
        internal
        view
        returns (
            bytes memory value,
            uint256 timestampRetrieved
        )
    {
        (
            bool found,
            bytes memory oracleValue,
            uint256 oracleTimestamp
        ) =
            tellor.getDataBefore(
                queryId,
                block.timestamp
            );

        if (!found) {
            revert OracleDataUnavailable();
        }

        if (
            block.timestamp -
            oracleTimestamp >
            maxOracleAge
        ) {
            revert StaleOracleData();
        }

        return (
            oracleValue,
            oracleTimestamp
        );
    }


    /**
     * @notice
     * Read the Tellor market/index price.
     *
     * Example:
     *
     * ETH/USD.
     */
    function getMarketPrice()
        external
        view
        returns (
            uint256 price,
            uint256 timestampRetrieved
        )
    {
        (
            bytes memory value,
            uint256 timestamp
        ) =
            _getTellorData(
                marketPriceQueryId
            );

        price =
            abi.decode(
                value,
                (uint256)
            );

        return (
            price,
            timestamp
        );
    }


    /**
     * @notice
     * Read collateral price from Tellor.
     *
     * Example:
     *
     * USDC/USD.
     */
    function getCollateralPrice()
        external
        view
        returns (
            uint256 price,
            uint256 timestampRetrieved
        )
    {
        (
            bytes memory value,
            uint256 timestamp
        ) =
            _getTellorData(
                collateralPriceQueryId
            );

        price =
            abi.decode(
                value,
                (uint256)
            );

        return (
            price,
            timestamp
        );
    }


    /*//////////////////////////////////////////////////////////////
                        BACKING STATUS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Verify ERC-1155 ePerp backing.
     *
     * The amount held by this contract should match
     * totalUnderlyingLocked.
     */
    function backingStatus()
        external
        view
        returns (
            uint256 actualUnderlying,
            uint256 accountedUnderlying
        )
    {
        actualUnderlying =
            underlyingPosition.balanceOf(
                address(this),
                underlyingClassId,
                underlyingNonceId
            );

        accountedUnderlying =
            totalUnderlyingLocked;
    }


    /*//////////////////////////////////////////////////////////////
                    SCHRODINGER CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function setSchrodingerHook(
        address hook
    )
        external
        onlyOwner
    {
        if (hook == address(0)) {
            revert ZeroAddress();
        }

        schrodingerHook =
            hook;

        emit SchrodingerHookUpdated(
            hook
        );
    }


    /*//////////////////////////////////////////////////////////////
                       ORACLE CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function setTellor(
        address tellor_
    )
        external
        onlyOwner
    {
        if (tellor_ == address(0)) {
            revert ZeroAddress();
        }

        tellor =
            ITellorPerpOracle(
                tellor_
            );

        emit TellorUpdated(
            tellor_
        );
    }


    function setOracleQueries(
        bytes32 marketQuery,
        bytes32 collateralQuery
    )
        external
        onlyOwner
    {
        marketPriceQueryId =
            marketQuery;

        collateralPriceQueryId =
            collateralQuery;

        emit OracleQueriesUpdated(
            marketQuery,
            collateralQuery
        );
    }


    function setMaxOracleAge(
        uint256 newMaxOracleAge
    )
        external
        onlyOwner
    {
        maxOracleAge =
            newMaxOracleAge;

        emit MaxOracleAgeUpdated(
            newMaxOracleAge
        );
    }


    /*//////////////////////////////////////////////////////////////
                         INFORMATION
    //////////////////////////////////////////////////////////////*/

    function instrument()
        external
        pure
        returns (string memory)
    {
        return
            "Coffhee ePerp";
    }


    function underlyingVenue()
        external
        pure
        returns (string memory)
    {
        return
            "GMX";
    }


    function architecture()
        external
        pure
        returns (string memory)
    {
        return
            "GMX Perp -> ERC-3475 -> ERC-1155 ePerp -> SchrodingerHook";
    }


    function privacyProtocol()
        external
        pure
        returns (string memory)
    {
        return
            "Fhenix CoFHE";
    }


    function oracleProtocol()
        external
        pure
        returns (string memory)
    {
        return
            "Tellor";
    }


    /*//////////////////////////////////////////////////////////////
                     ERC-1155 INTERFACE SUPPORT
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(
            ERC1155,
            ERC1155Holder
        )
        returns (bool)
    {
        return
            super.supportsInterface(
                interfaceId
            );
    }
}