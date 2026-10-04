// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title QatarSukuk3475 + eBond
 * @author Coffhee Finance
 *
 * @notice
 * Open House prototype demonstrating the Coffhee eBond architecture.
 *
 * Architecture:
 *
 * Qatar Sukuk / Tokenized Bond
 *          |
 *          v
 * QatarSukuk3475
 * ERC-3475-style financial instrument
 *          |
 *          | deposit / lock
 *          v
 *        eBond
 * ERC-1155 Coffhee wrapper
 *          |
 *          +---- Fhenix CoFHE encrypted metadata
 *          |
 *          +---- Tellor market data
 *          |
 *          v
 *   SchrodingerHook
 *
 * IMPORTANT
 * ---------
 * This contract is an Open House demonstration.
 *
 * It does NOT represent an officially issued token from the
 * Government of Qatar, Qatar Central Bank, QFC, or the actual
 * securities depository.
 *
 * The real-world instrument is used as reference data for demonstrating
 * how an already-tokenized bond/Sukuk could be represented inside
 * Coffhee.
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
 * Fhenix CoFHE types.
 *
 * Exact package path may differ depending on the pinned CoFHE version.
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
 * Minimal Tellor interface needed by the eBond.
 *
 * Tellor query data is identified using a queryId.
 *
 * For the Open House implementation, the frontend/indexer can build
 * the appropriate Tellor query for:
 *
 * - Sukuk/bond market price
 * - QAR/USD
 * - benchmark rates
 * - other external market information
 */
interface ITellorOracle {

    function getDataBefore(
        bytes32 _queryId,
        uint256 _timestamp
    )
        external
        view
        returns (
            bool _ifRetrieve,
            bytes memory _value,
            uint256 _timestampRetrieved
        );
}


/*//////////////////////////////////////////////////////////////
                SIMPLE ERC-3475-STYLE BOND
//////////////////////////////////////////////////////////////*/

/**
 * @title QatarSukuk3475
 *
 * @notice
 * Simplified ERC-3475-style tokenized representation of:
 *
 * Qatar Government Sukuk
 * 4.75%
 * Maturity: 15 April 2029
 *
 * ISIN:
 * QA0000MSXYK7
 *
 * FIGI:
 * BBG01N78QC71
 *
 * Registration:
 * QA0035210061
 *
 * Face Value:
 * QAR 10,000
 *
 * Reference outstanding amount:
 * QAR 600,000,000
 *
 * ERC-3475 concept:
 *
 * CLASS = financial instrument
 * NONCE = issuance
 *
 * For this demo:
 *
 * CLASS_ID = 1
 * NONCE_ID = 20290415
 */
contract QatarSukuk3475 is Ownable {

    /*//////////////////////////////////////////////////////////////
                            STRUCTURES
    //////////////////////////////////////////////////////////////*/

    struct Transaction {
        uint256 classId;
        uint256 nonceId;
        uint256 amount;
    }

    struct BondData {

        string name;

        string issuer;

        string jurisdiction;

        string currency;

        string isin;

        string figi;

        string registrationNumber;

        string instrumentType;

        uint256 profitRateBps;

        uint256 faceValueQAR;

        uint256 maturityTimestamp;

        uint256 referenceOutstandingQAR;

        bool senior;

        bool unsecured;

        bool islamicFinanceInstrument;
    }


    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant CLASS_ID = 1;

    uint256 public constant NONCE_ID = 20290415;

    uint256 public constant PROFIT_RATE_BPS = 475;

    uint256 public constant FACE_VALUE_QAR = 10_000;

    uint256 public constant REFERENCE_OUTSTANDING_QAR =
        600_000_000;

    /**
     * 2029-04-15 00:00:00 UTC
     */
    uint256 public constant MATURITY_TIMESTAMP =
        1870905600;


    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    BondData private _bond;

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

    event Issue(
        address indexed to,
        uint256 indexed classId,
        uint256 indexed nonceId,
        uint256 amount
    );

    event Transfer(
        address indexed from,
        address indexed to,
        uint256 indexed classId,
        uint256 nonceId,
        uint256 amount
    );

    event Redeem(
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


    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidBond();

    error ZeroAddress();

    error ZeroAmount();

    error InsufficientBalance();

    error Unauthorized();


    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address initialOwner
    )
        Ownable(initialOwner)
    {
        _bond = BondData({

            name:
                "Qatar Government Sukuk 4.75% 15APR2029",

            issuer:
                "State of Qatar",

            jurisdiction:
                "Qatar",

            currency:
                "QAR",

            isin:
                "QA0000MSXYK7",

            figi:
                "BBG01N78QC71",

            registrationNumber:
                "QA0035210061",

            instrumentType:
                "Sukuk",

            profitRateBps:
                PROFIT_RATE_BPS,

            faceValueQAR:
                FACE_VALUE_QAR,

            maturityTimestamp:
                MATURITY_TIMESTAMP,

            referenceOutstandingQAR:
                REFERENCE_OUTSTANDING_QAR,

            senior:
                true,

            unsecured:
                true,

            islamicFinanceInstrument:
                true
        });
    }


    /*//////////////////////////////////////////////////////////////
                          BOND DISCLOSURE
    //////////////////////////////////////////////////////////////*/

    function bondData()
        external
        view
        returns (BondData memory)
    {
        return _bond;
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
                          ERC-3475 BALANCE
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
            _balances[account][classId_][nonceId_];
    }


    /*//////////////////////////////////////////////////////////////
                             ISSUANCE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Prototype issuer function.
     *
     * One unit represents one QAR 10,000 face-value Sukuk unit
     * for this Open House model.
     */
    function issue(
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

            _validateBond(
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

            emit Issue(
                to,
                txn.classId,
                txn.nonceId,
                txn.amount
            );
        }
    }


    /*//////////////////////////////////////////////////////////////
                            TRANSFERS
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

            _validateBond(
                txn.classId,
                txn.nonceId
            );

            uint256 fromBalance =
                _balances[from]
                    [txn.classId]
                    [txn.nonceId];

            if (fromBalance < txn.amount) {
                revert InsufficientBalance();
            }

            unchecked {

                _balances[from]
                    [txn.classId]
                    [txn.nonceId]
                    =
                    fromBalance -
                    txn.amount;
            }

            _balances[to]
                [txn.classId]
                [txn.nonceId]
                += txn.amount;

            emit Transfer(
                from,
                to,
                txn.classId,
                txn.nonceId,
                txn.amount
            );
        }
    }


    /*//////////////////////////////////////////////////////////////
                          OPERATOR APPROVAL
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
                             REDEMPTION
    //////////////////////////////////////////////////////////////*/

    function redeem(
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

            _validateBond(
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

            emit Redeem(
                from,
                txn.classId,
                txn.nonceId,
                txn.amount
            );
        }
    }


    /*//////////////////////////////////////////////////////////////
                             INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _validateBond(
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
            revert InvalidBond();
        }
    }
}


/*//////////////////////////////////////////////////////////////
                    COFFHEE eBOND WRAPPER
//////////////////////////////////////////////////////////////*/

/**
 * @title eBond
 *
 * @notice
 * Coffhee's ERC-1155 confidential wrapper around the
 * ERC-3475 Qatar Sukuk.
 *
 * Users:
 *
 * 1. Own the ERC-3475 underlying bond.
 *
 * 2. Deposit/lock it into eBond.
 *
 * 3. Receive ERC-1155 eBond units.
 *
 * 4. Use eBond inside Coffhee / SchrodingerHook.
 *
 * 5. Burn eBond to recover the underlying ERC-3475 instrument.
 *
 *
 * PUBLIC INFORMATION
 * ------------------
 *
 * - issuer
 * - ISIN
 * - FIGI
 * - maturity
 * - profit rate
 * - face value
 * - jurisdiction
 * - instrument type
 *
 *
 * CONFIDENTIAL INFORMATION
 * ------------------------
 *
 * - acquisition price
 * - investor cost basis
 * - portfolio target allocation
 * - rebalance threshold
 * - private strategy parameters
 * - private valuation parameters
 *
 *
 * This is intentional:
 *
 * The financial instrument remains transparent.
 *
 * The HOLDER'S financial strategy can remain confidential.
 */
contract eBond is
    ERC1155,
    ERC1155Holder,
    Ownable,
    ReentrancyGuard
{

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant EBOND_ID = 1;


    /*//////////////////////////////////////////////////////////////
                         UNDERLYING ASSET
    //////////////////////////////////////////////////////////////*/

    QatarSukuk3475 public immutable underlyingBond;

    uint256 public immutable underlyingClassId;

    uint256 public immutable underlyingNonceId;


    /*//////////////////////////////////////////////////////////////
                          SCHRODINGER HOOK
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Authorized Coffhee SchrodingerHook.
     *
     * The hook can be used by the frontend/integration layer
     * to identify the market authorized to interact with eBond.
     */
    address public schrodingerHook;


    /*//////////////////////////////////////////////////////////////
                              TELLOR
    //////////////////////////////////////////////////////////////*/

    ITellorOracle public tellor;

    /**
     * @notice
     * Tellor query ID representing the market-data query used
     * for this eBond.
     *
     * The exact query can represent a bond-price feed or other
     * relevant market input configured for the prototype.
     */
    bytes32 public marketDataQueryId;


    /*//////////////////////////////////////////////////////////////
                     CONFIDENTIAL HOLDER DATA
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Encrypted acquisition price.
     *
     * Example conceptual value:
     *
     * holder => encrypted QAR price
     */
    mapping(address => euint64)
        private _encryptedAcquisitionPrice;


    /**
     * @notice
     * Encrypted portfolio target allocation.
     *
     * Example:
     *
     * 2500 = 25.00%
     */
    mapping(address => euint64)
        private _encryptedTargetAllocationBps;


    /**
     * @notice
     * Encrypted rebalance threshold.
     *
     * Example:
     *
     * 500 = 5.00%
     */
    mapping(address => euint64)
        private _encryptedRebalanceThresholdBps;


    /**
     * @notice
     * Encrypted investor-specific strategy value.
     *
     * This intentionally remains generic for the Open House demo.
     *
     * It could later represent:
     *
     * duration target,
     * yield target,
     * risk threshold,
     * maximum allocation,
     * etc.
     */
    mapping(address => euint64)
        private _encryptedStrategyParameter;


    /*//////////////////////////////////////////////////////////////
                           WRAPPER ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Total underlying ERC-3475 units locked in Coffhee.
     */
    uint256 public totalUnderlyingLocked;


    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event BondWrapped(
        address indexed holder,
        uint256 underlyingAmount,
        uint256 eBondAmount
    );

    event BondUnwrapped(
        address indexed holder,
        uint256 eBondAmount,
        uint256 underlyingAmount
    );

    event PrivateStrategyUpdated(
        address indexed holder
    );

    event SchrodingerHookUpdated(
        address indexed hook
    );

    event TellorUpdated(
        address indexed tellor
    );

    event TellorQueryUpdated(
        bytes32 indexed queryId
    );


    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();

    error ZeroAmount();

    error InsufficientEBond();

    error UnderlyingTransferFailed();

    error OracleDataUnavailable();

    error StaleOracleData();


    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address initialOwner,
        address underlyingBond_,
        address tellor_,
        bytes32 marketDataQueryId_,
        string memory metadataURI
    )
        ERC1155(metadataURI)
        Ownable(initialOwner)
    {
        if (
            initialOwner == address(0) ||
            underlyingBond_ == address(0) ||
            tellor_ == address(0)
        ) {
            revert ZeroAddress();
        }

        underlyingBond =
            QatarSukuk3475(
                underlyingBond_
            );

        underlyingClassId =
            QatarSukuk3475(
                underlyingBond_
            ).CLASS_ID();

        underlyingNonceId =
            QatarSukuk3475(
                underlyingBond_
            ).NONCE_ID();

        tellor =
            ITellorOracle(
                tellor_
            );

        marketDataQueryId =
            marketDataQueryId_;
    }


    /*//////////////////////////////////////////////////////////////
                        WRAP ERC-3475 -> ERC-1155
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Lock underlying ERC-3475 Sukuk and mint Coffhee eBond.
     *
     * Before calling:
     *
     * underlyingBond.setApprovalFor(
     *     address(eBond),
     *     true
     * );
     *
     * Ratio:
     *
     * 1 underlying bond unit
     * =
     * 1 eBond ERC-1155 unit
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
            underlyingBond.balanceOf(
                address(this),
                underlyingClassId,
                underlyingNonceId
            );

        QatarSukuk3475.Transaction[]
            memory transactions =
                new QatarSukuk3475.Transaction[](1);

        transactions[0] =
            QatarSukuk3475.Transaction({
                classId:
                    underlyingClassId,

                nonceId:
                    underlyingNonceId,

                amount:
                    amount
            });

        underlyingBond.transferFrom(
            msg.sender,
            address(this),
            transactions
        );

        uint256 balanceAfter =
            underlyingBond.balanceOf(
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
            EBOND_ID,
            amount,
            ""
        );

        emit BondWrapped(
            msg.sender,
            amount,
            amount
        );
    }


    /*//////////////////////////////////////////////////////////////
                       UNWRAP ERC-1155 -> ERC-3475
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Burn Coffhee eBond and release underlying Sukuk.
     */
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
                EBOND_ID
            ) < amount
        ) {
            revert InsufficientEBond();
        }

        _burn(
            msg.sender,
            EBOND_ID,
            amount
        );

        totalUnderlyingLocked -=
            amount;

        QatarSukuk3475.Transaction[]
            memory transactions =
                new QatarSukuk3475.Transaction[](1);

        transactions[0] =
            QatarSukuk3475.Transaction({
                classId:
                    underlyingClassId,

                nonceId:
                    underlyingNonceId,

                amount:
                    amount
            });

        underlyingBond.transferFrom(
            address(this),
            msg.sender,
            transactions
        );

        emit BondUnwrapped(
            msg.sender,
            amount,
            amount
        );
    }


    /*//////////////////////////////////////////////////////////////
                     CONFIDENTIAL STRATEGY DATA
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Store encrypted holder-specific strategy information.
     *
     * The client encrypts these values with Fhenix CoFHE before
     * submitting the transaction.
     *
     * Nothing here requires the user to reveal the plaintext.
     */
    function setPrivateStrategy(
        InEuint64 calldata acquisitionPrice,
        InEuint64 calldata targetAllocationBps,
        InEuint64 calldata rebalanceThresholdBps,
        InEuint64 calldata strategyParameter
    )
        external
    {
        if (
            balanceOf(
                msg.sender,
                EBOND_ID
            ) == 0
        ) {
            revert InsufficientEBond();
        }

        _encryptedAcquisitionPrice[
            msg.sender
        ] =
            FHE.asEuint64(
                acquisitionPrice
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
         * Give the holder permission to access/decrypt their
         * own encrypted values.
         *
         * Exact CoFHE permission API should be pinned to the
         * version installed in the Foundry project.
         */
        FHE.allow(
            _encryptedAcquisitionPrice[msg.sender],
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
         * Allow this contract to continue performing FHE operations
         * against the ciphertexts.
         */
        FHE.allowThis(
            _encryptedAcquisitionPrice[msg.sender]
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

        emit PrivateStrategyUpdated(
            msg.sender
        );
    }


    /*//////////////////////////////////////////////////////////////
                       PRIVATE REBALANCING SIGNAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Produces an encrypted indication of whether the holder's
     * allocation exceeds their confidential target + threshold.
     *
     * IMPORTANT:
     *
     * For the production SchrodingerHook integration this computation
     * would feed the hook/rebalance controller without revealing:
     *
     * - target allocation
     * - threshold
     * - strategy parameter
     *
     * This prototype returns the encrypted computation handle.
     */
    function encryptedRebalanceThreshold(
        address holder
    )
        external
        view
        returns (euint64)
    {
        /*
         * target + threshold remains encrypted.
         */

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


    /*//////////////////////////////////////////////////////////////
                          TELLOR MARKET DATA
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Read the most recent Tellor value before the supplied timestamp.
     *
     * The meaning/decimals of the returned value are defined by the
     * Tellor query associated with marketDataQueryId.
     *
     * Example query:
     *
     * Qatar Sukuk indicative market price
     *
     * or:
     *
     * QAR/USD
     *
     * For production, use a precisely specified Tellor query type
     * and documented decimal convention.
     */
    function getTellorMarketData(
        uint256 beforeTimestamp
    )
        public
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
                marketDataQueryId,
                beforeTimestamp
            );

        if (!found) {
            revert OracleDataUnavailable();
        }

        return (
            oracleValue,
            oracleTimestamp
        );
    }


    /**
     * @notice
     * Convenience function for uint256 Tellor values.
     */
    function getTellorUint(
        uint256 beforeTimestamp
    )
        external
        view
        returns (
            uint256 value,
            uint256 timestampRetrieved
        )
    {
        (
            bytes memory oracleValue,
            uint256 oracleTimestamp
        ) =
            getTellorMarketData(
                beforeTimestamp
            );

        value =
            abi.decode(
                oracleValue,
                (uint256)
            );

        return (
            value,
            oracleTimestamp
        );
    }


    /*//////////////////////////////////////////////////////////////
                       COLLATERALIZATION CHECK
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Demonstrates that every outstanding eBond is backed by
     * underlying ERC-3475 units.
     */
    function backingStatus()
        external
        view
        returns (
            uint256 underlyingLocked,
            uint256 accountedLocked
        )
    {
        underlyingLocked =
            underlyingBond.balanceOf(
                address(this),
                underlyingClassId,
                underlyingNonceId
            );

        accountedLocked =
            totalUnderlyingLocked;
    }


    /*//////////////////////////////////////////////////////////////
                     SCHRODINGER HOOK CONFIG
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
                         TELLOR CONFIG
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
            ITellorOracle(
                tellor_
            );

        emit TellorUpdated(
            tellor_
        );
    }


    function setMarketDataQueryId(
        bytes32 queryId
    )
        external
        onlyOwner
    {
        marketDataQueryId =
            queryId;

        emit TellorQueryUpdated(
            queryId
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
            "Coffhee eBond";
    }


    function architecture()
        external
        pure
        returns (string memory)
    {
        return
            "ERC-3475 underlying / ERC-1155 Coffhee wrapper / Fhenix CoFHE / Tellor";
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
                     ERC-1155 RECEIVER SUPPORT
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