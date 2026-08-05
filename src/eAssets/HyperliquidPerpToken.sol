// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ERC3475
 * @notice Minimal ERC-3475 base API used by Coffhee Finance.
 */
abstract contract ERC3475 {
    struct Transaction {
        uint256 classId;
        uint256 nonceId;
        uint256 amount;
    }

    event ApprovalFor(address indexed owner, address indexed operator, bool approved);
    event Issue(address indexed operator, address indexed to, Transaction[] transactions);
    event Redeem(address indexed operator, address indexed from, Transaction[] transactions);
    event Transfer(
        address indexed operator,
        address indexed from,
        address indexed to,
        Transaction[] transactions
    );

    function issue(address to, Transaction[] calldata transactions) external virtual;
    function redeem(address from, Transaction[] calldata transactions) external virtual;
    function transferFrom(address from, address to, Transaction[] calldata transactions) external virtual;
    function setApprovalFor(address operator, bool approved) external virtual;
    function balanceOf(address account, uint256 classId, uint256 nonceId) external view virtual returns (uint256);
    function isApprovedFor(address account, address operator) external view virtual returns (bool);
}

/**
 * @title HyperliquidPerpToken
 * @notice ERC-3475-style tokenized obligation representing a perpetual-futures asset.
 * @dev A class identifies the perpetual market, while a nonce identifies a specific
 *      issuance series or position configuration within that market.
 *
 *      The contract intentionally stores market and instrument information in plaintext.
 *      Sensitive ownership and legal-document information belongs in the encrypted
 *      ERC-1155 wrapper contract.
 */

 //ArbSepolia Address: 0x3dcEF76b08A7452611A75B258434a4B449Db1e3f
 
contract HyperliquidPerpToken is ERC3475, Ownable, ReentrancyGuard {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum PositionSide {
        LONG,
        SHORT
    }

    enum MarginMode {
        CROSS,
        ISOLATED
    }

    enum PositionStatus {
        PENDING,
        ACTIVE,
        CLOSED,
        LIQUIDATED,
        CANCELLED
    }

    struct ClassData {
        string name;
        string symbol;
        string underlyingAsset;
        string quoteAsset;
        string venue;
        string marketIdentifier;
        uint8 settlementDecimals;
        bool active;
        bool exists;
    }

    struct PerpData {
        PositionSide side;
        MarginMode marginMode;
        PositionStatus status;
        uint64 openedAt;
        uint64 expiryOrReviewTime;
        uint64 lastUpdatedAt;
        uint32 maxLeverageBps;
        uint32 maintenanceMarginBps;
        uint32 initialMarginBps;
        uint32 liquidationFeeBps;
        uint128 entryPrice;
        uint128 markPriceAtIssuance;
        uint128 liquidationPrice;
        uint128 notionalValue;
        uint128 collateralValue;
        int128 fundingRateBps;
        bytes32 externalPositionId;
        bytes32 oracleMarketId;
        string publicMetadataURI;
        bool transferable;
        bool redeemable;
        bool exists;
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    string public name;
    string public symbol;

    uint256 public nextClassId = 1;

    mapping(uint256 classId => ClassData) private _classes;
    mapping(uint256 classId => mapping(uint256 nonceId => PerpData)) private _perps;

    mapping(address account => mapping(uint256 classId => mapping(uint256 nonceId => uint256)))
        private _balances;

    mapping(uint256 classId => mapping(uint256 nonceId => uint256)) private _totalSupply;
    mapping(address account => mapping(address operator => bool)) private _operatorApprovals;
    mapping(address issuer => bool) public approvedIssuers;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ClassCreated(uint256 indexed classId, string symbol, string marketIdentifier);
    event ClassStatusSet(uint256 indexed classId, bool active);
    event PerpSeriesCreated(uint256 indexed classId, uint256 indexed nonceId, bytes32 externalPositionId);
    event PerpSeriesUpdated(uint256 indexed classId, uint256 indexed nonceId, PositionStatus status);
    event IssuerSet(address indexed issuer, bool approved);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error EmptyTransactions();
    error ClassNotFound(uint256 classId);
    error SeriesNotFound(uint256 classId, uint256 nonceId);
    error ClassInactive(uint256 classId);
    error SeriesNotTransferable(uint256 classId, uint256 nonceId);
    error SeriesNotRedeemable(uint256 classId, uint256 nonceId);
    error Unauthorized();
    error InsufficientBalance(uint256 classId, uint256 nonceId, uint256 requested, uint256 available);
    error InvalidAmount();
    error InvalidBps();
    error SeriesAlreadyExists(uint256 classId, uint256 nonceId);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        name = "Coffhee Hyperliquid Perpetual Assets";
        symbol = "HLPERP-3475";
        approvedIssuers[initialOwner] = true;
        emit IssuerSet(initialOwner, true);
    }

    // -------------------------------------------------------------------------
    // Administration
    // -------------------------------------------------------------------------

    function setIssuer(address issuer, bool approved) external onlyOwner {
        if (issuer == address(0)) revert ZeroAddress();
        approvedIssuers[issuer] = approved;
        emit IssuerSet(issuer, approved);
    }

    function createClass(ClassData calldata classData) external onlyOwner returns (uint256 classId) {
        if (bytes(classData.symbol).length == 0 || bytes(classData.marketIdentifier).length == 0) {
            revert Unauthorized();
        }

        classId = nextClassId++;
        _classes[classId] = ClassData({
            name: classData.name,
            symbol: classData.symbol,
            underlyingAsset: classData.underlyingAsset,
            quoteAsset: classData.quoteAsset,
            venue: classData.venue,
            marketIdentifier: classData.marketIdentifier,
            settlementDecimals: classData.settlementDecimals,
            active: classData.active,
            exists: true
        });

        emit ClassCreated(classId, classData.symbol, classData.marketIdentifier);
    }

    function setClassStatus(uint256 classId, bool active) external onlyOwner {
        ClassData storage classInfo = _requireClass(classId);
        classInfo.active = active;
        emit ClassStatusSet(classId, active);
    }

    function createPerpSeries(
        uint256 classId,
        uint256 nonceId,
        PerpData calldata perpData
    ) external onlyOwner {
        ClassData storage classInfo = _requireClass(classId);
        if (!classInfo.active) revert ClassInactive(classId);
        if (_perps[classId][nonceId].exists) revert SeriesAlreadyExists(classId, nonceId);

        _validatePerpData(perpData);
        _perps[classId][nonceId] = perpData;
        _perps[classId][nonceId].exists = true;
        _perps[classId][nonceId].lastUpdatedAt = uint64(block.timestamp);

        emit PerpSeriesCreated(classId, nonceId, perpData.externalPositionId);
    }

    function updateMarketSnapshot(
        uint256 classId,
        uint256 nonceId,
        uint128 markPrice,
        uint128 liquidationPrice,
        int128 fundingRateBps,
        PositionStatus status,
        bool transferable,
        bool redeemable
    ) external onlyOwner {
        PerpData storage perp = _requireSeries(classId, nonceId);
        perp.markPriceAtIssuance = markPrice;
        perp.liquidationPrice = liquidationPrice;
        perp.fundingRateBps = fundingRateBps;
        perp.status = status;
        perp.transferable = transferable;
        perp.redeemable = redeemable;
        perp.lastUpdatedAt = uint64(block.timestamp);

        emit PerpSeriesUpdated(classId, nonceId, status);
    }

    // -------------------------------------------------------------------------
    // ERC-3475 issuance, redemption and transfers
    // -------------------------------------------------------------------------

    function issue(address to, Transaction[] calldata transactions) external override nonReentrant {
        if (!approvedIssuers[msg.sender]) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        if (transactions.length == 0) revert EmptyTransactions();

        for (uint256 i; i < transactions.length; ++i) {
            Transaction calldata item = transactions[i];
            if (item.amount == 0) revert InvalidAmount();

            ClassData storage classInfo = _requireClass(item.classId);
            if (!classInfo.active) revert ClassInactive(item.classId);
            _requireSeries(item.classId, item.nonceId);

            _balances[to][item.classId][item.nonceId] += item.amount;
            _totalSupply[item.classId][item.nonceId] += item.amount;
        }

        emit Issue(msg.sender, to, transactions);
    }

    function redeem(address from, Transaction[] calldata transactions) external override nonReentrant {
        if (from == address(0)) revert ZeroAddress();
        if (!_isAuthorized(from, msg.sender) && !approvedIssuers[msg.sender]) revert Unauthorized();
        if (transactions.length == 0) revert EmptyTransactions();

        for (uint256 i; i < transactions.length; ++i) {
            Transaction calldata item = transactions[i];
            if (item.amount == 0) revert InvalidAmount();

            PerpData storage perp = _requireSeries(item.classId, item.nonceId);
            if (!perp.redeemable) revert SeriesNotRedeemable(item.classId, item.nonceId);

            _debit(from, item.classId, item.nonceId, item.amount);
            _totalSupply[item.classId][item.nonceId] -= item.amount;
        }

        emit Redeem(msg.sender, from, transactions);
    }

    function transferFrom(
        address from,
        address to,
        Transaction[] calldata transactions
    ) external override nonReentrant {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (!_isAuthorized(from, msg.sender)) revert Unauthorized();
        if (transactions.length == 0) revert EmptyTransactions();

        for (uint256 i; i < transactions.length; ++i) {
            Transaction calldata item = transactions[i];
            if (item.amount == 0) revert InvalidAmount();

            PerpData storage perp = _requireSeries(item.classId, item.nonceId);
            if (!perp.transferable) revert SeriesNotTransferable(item.classId, item.nonceId);

            _debit(from, item.classId, item.nonceId, item.amount);
            _balances[to][item.classId][item.nonceId] += item.amount;
        }

        emit Transfer(msg.sender, from, to, transactions);
    }

    function setApprovalFor(address operator, bool approved) external override {
        if (operator == address(0)) revert ZeroAddress();
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalFor(msg.sender, operator, approved);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function classData(uint256 classId) external view returns (ClassData memory) {
        return _requireClass(classId);
    }

    function perpData(uint256 classId, uint256 nonceId) external view returns (PerpData memory) {
        return _requireSeries(classId, nonceId);
    }

    function balanceOf(address account, uint256 classId, uint256 nonceId) external view override returns (uint256) {
        return _balances[account][classId][nonceId];
    }

    function totalSupply(uint256 classId, uint256 nonceId) external view returns (uint256) {
        return _totalSupply[classId][nonceId];
    }

    function isApprovedFor(address account, address operator) external view override returns (bool) {
        return _operatorApprovals[account][operator];
    }

    function classValues(uint256 classId) external view returns (ClassData memory) {
        return _requireClass(classId);
    }

    function nonceValues(uint256 classId, uint256 nonceId) external view returns (PerpData memory) {
        return _requireSeries(classId, nonceId);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _requireClass(uint256 classId) internal view returns (ClassData storage classInfo) {
        classInfo = _classes[classId];
        if (!classInfo.exists) revert ClassNotFound(classId);
    }

    function _requireSeries(
        uint256 classId,
        uint256 nonceId
    ) internal view returns (PerpData storage perp) {
        perp = _perps[classId][nonceId];
        if (!perp.exists) revert SeriesNotFound(classId, nonceId);
    }

    function _isAuthorized(address account, address operator) internal view returns (bool) {
        return account == operator || _operatorApprovals[account][operator];
    }

    function _debit(address from, uint256 classId, uint256 nonceId, uint256 amount) internal {
        uint256 available = _balances[from][classId][nonceId];
        if (available < amount) {
            revert InsufficientBalance(classId, nonceId, amount, available);
        }
        unchecked {
            _balances[from][classId][nonceId] = available - amount;
        }
    }

    function _validatePerpData(PerpData calldata perpData) internal pure {
        if (
            perpData.maxLeverageBps > 1_000_000 ||
            perpData.maintenanceMarginBps > 10_000 ||
            perpData.initialMarginBps > 10_000 ||
            perpData.liquidationFeeBps > 10_000
        ) revert InvalidBps();
    }
}
