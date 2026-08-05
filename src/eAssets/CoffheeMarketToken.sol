// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {
    FHE,
    eaddress,
    euint128,
    InEaddress,
    InEuint128
} from "cofhe-contracts/FHE.sol";

import {HyperliquidPerpToken, ERC3475} from "./HyperliquidPerpToken.sol";

/**
 * @title CoffheeMarketToken
 * @author Coffhee Finance
 *
 * @notice Encrypted ERC-1155 market token that wraps and escrows
 *         ERC-3475 asset positions.
 *
 * @dev Each wrapped ERC-3475 position receives a unique ERC-1155 token ID.
 *
 * Public information:
 * - ERC-3475 class ID
 * - ERC-3475 nonce ID
 * - wrapped quantity
 * - ERC-1155 holder
 * - record manager
 * - creation timestamp
 *
 * Encrypted information:
 * - beneficial owner
 * - legal-agreement fingerprint
 * - corporate-document fingerprint
 * - ownership or cap-table reference
 *
 * PRIVACY MODEL
 *
 * ERC-1155 holder addresses, balances, approvals, and transfers remain public.
 * The ERC-1155 token can therefore be held by a Schrodinger pool, vault,
 * custodian, escrow, or market contract while the actual beneficial owner
 * remains encrypted using a CoFHE eaddress.
 *
 * Legal agreements and corporate documents should remain encrypted off-chain.
 * This contract stores encrypted document fingerprints or identifiers rather
 * than full document contents.
 */

 //ArbSepolia address: 0x57f9702D8EDf9A6dE62A8184f98971f09DB93F0F

contract CoffheeMarketToken is ERC1155, Ownable, ReentrancyGuard {
    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /**
     * @notice Public information describing an ERC-1155 wrapped position.
     */
    struct WrappedPosition {
        uint256 classId;
        uint256 nonceId;
        uint256 amount;
        address recordManager;
        uint64 createdAt;
        bool active;
    }

    /**
     * @notice Confidential information associated with a wrapped position.
     *
     * @dev Document fingerprints are divided into two encrypted 128-bit values
     *      because CoFHE supports euint128 encrypted integer values.
     */
    struct ConfidentialRecord {
        eaddress beneficialOwner;

        euint128 legalAgreementHashHigh;
        euint128 legalAgreementHashLow;

        euint128 corporateDocumentHashHigh;
        euint128 corporateDocumentHashLow;

        euint128 ownershipReferenceHigh;
        euint128 ownershipReferenceLow;
    }

    // -------------------------------------------------------------------------
    // Immutable configuration
    // -------------------------------------------------------------------------

    /**
     * @notice ERC-3475 asset contract whose positions are wrapped.
     */
    HyperliquidPerpToken public immutable underlying;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /**
     * @notice Next ERC-1155 token ID that will be assigned.
     */
    uint256 public nextTokenId = 1;

    /**
     * @notice Authorized SchrodingerHook address.
     */
    address public schrodingerHook;

    /**
     * @notice Public position information for each ERC-1155 token ID.
     */
    mapping(uint256 tokenId => WrappedPosition) private _positions;

    /**
     * @notice Encrypted information for each ERC-1155 token ID.
     */
    mapping(uint256 tokenId => ConfidentialRecord) private _confidentialRecords;

    /**
     * @notice Contracts approved to participate in Schrodinger market pools.
     */
    mapping(address operator => bool approved) public approvedPoolOperators;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event EAssetWrapped(
        uint256 indexed tokenId,
        uint256 indexed classId,
        uint256 indexed nonceId,
        address publicHolder,
        uint256 amount
    );

    event EAssetUnwrapped(
        uint256 indexed tokenId,
        address indexed recipient,
        uint256 amount
    );

    event ConfidentialRecordUpdated(
        uint256 indexed tokenId,
        address indexed recordManager
    );

    event ConfidentialViewerGranted(
        uint256 indexed tokenId,
        address indexed viewer
    );

    event RecordManagerTransferred(
        uint256 indexed tokenId,
        address indexed previousManager,
        address indexed newManager
    );

    event SchrodingerHookSet(address indexed hook);

    event PoolOperatorSet(
        address indexed operator,
        bool approved
    );

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error InvalidAmount();
    error PositionNotFound(uint256 tokenId);
    error Unauthorized();
    error PositionInactive(uint256 tokenId);

    error InsufficientWrappedBalance(
        uint256 tokenId,
        uint256 requested,
        uint256 available
    );

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /**
     * @notice Restricts access to the record manager or contract owner.
     */
    modifier onlyRecordManager(uint256 tokenId) {
        WrappedPosition storage wrappedPosition = _positions[tokenId];

        if (!wrappedPosition.active) {
            revert PositionNotFound(tokenId);
        }

        if (
            msg.sender != wrappedPosition.recordManager
                && msg.sender != owner()
        ) {
            revert Unauthorized();
        }

        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @param initialOwner Initial owner of the Coffhee market-token contract.
     * @param underlying_ ERC-3475 contract containing the underlying assets.
     * @param baseURI Base metadata URI for ERC-1155 tokens.
     */
    constructor(
        address initialOwner,
        HyperliquidPerpToken underlying_,
        string memory baseURI
    ) ERC1155(baseURI) Ownable(initialOwner) {
        if (
            initialOwner == address(0)
                || address(underlying_) == address(0)
        ) {
            revert ZeroAddress();
        }

        underlying = underlying_;
    }

    // -------------------------------------------------------------------------
    // Wrapping
    // -------------------------------------------------------------------------

    /**
     * @notice Escrows an ERC-3475 position and mints an encrypted ERC-1155
     *         Coffhee market token.
     *
     * @param publicHolder Address receiving the ERC-1155 token. This can be a
     *        Schrodinger pool, vault, escrow, custodian, or user wallet.
     *
     * @param classId ERC-3475 asset class.
     * @param nonceId ERC-3475 issuance or position nonce.
     * @param amount Number of ERC-3475 units to escrow and ERC-1155 units to mint.
     *
     * @param beneficialOwner Encrypted beneficial-owner address.
     *
     * @param legalHashHigh Encrypted high 128 bits of the legal-agreement hash.
     * @param legalHashLow Encrypted low 128 bits of the legal-agreement hash.
     *
     * @param corporateHashHigh Encrypted high 128 bits of the corporate-document hash.
     * @param corporateHashLow Encrypted low 128 bits of the corporate-document hash.
     *
     * @param ownershipRefHigh Encrypted high 128 bits of an ownership reference.
     * @param ownershipRefLow Encrypted low 128 bits of an ownership reference.
     *
     * @return tokenId Newly created ERC-1155 token ID.
     *
     * @dev The caller must approve this contract as an operator on the
     *      HyperliquidPerpToken contract before calling this function.
     */
    function wrap(
        address publicHolder,
        uint256 classId,
        uint256 nonceId,
        uint256 amount,
        InEaddress calldata beneficialOwner,
        InEuint128 calldata legalHashHigh,
        InEuint128 calldata legalHashLow,
        InEuint128 calldata corporateHashHigh,
        InEuint128 calldata corporateHashLow,
        InEuint128 calldata ownershipRefHigh,
        InEuint128 calldata ownershipRefLow
    ) external nonReentrant returns (uint256 tokenId) {
        if (publicHolder == address(0)) {
            revert ZeroAddress();
        }

        if (amount == 0) {
            revert InvalidAmount();
        }

        ERC3475.Transaction[]
            memory transactions =
                new ERC3475.Transaction[](1);

        transactions[0] = ERC3475.Transaction({
            classId: classId,
            nonceId: nonceId,
            amount: amount
        });

        /*
         * Move the ERC-3475 asset from the user into this wrapper contract.
         */
        underlying.transferFrom(
            msg.sender,
            address(this),
            transactions
        );

        tokenId = nextTokenId;
        nextTokenId++;

        _positions[tokenId] = WrappedPosition({
            classId: classId,
            nonceId: nonceId,
            amount: amount,
            recordManager: msg.sender,
            createdAt: uint64(block.timestamp),
            active: true
        });

        _storeConfidentialRecord(
            tokenId,
            beneficialOwner,
            legalHashHigh,
            legalHashLow,
            corporateHashHigh,
            corporateHashLow,
            ownershipRefHigh,
            ownershipRefLow,
            msg.sender
        );

        /*
         * Mint ERC-1155 market tokens representing the escrowed ERC-3475 units.
         */
        _mint(
            publicHolder,
            tokenId,
            amount,
            ""
        );

        emit EAssetWrapped(
            tokenId,
            classId,
            nonceId,
            publicHolder,
            amount
        );
    }

    // -------------------------------------------------------------------------
    // Unwrapping
    // -------------------------------------------------------------------------

    /**
     * @notice Burns Coffhee ERC-1155 tokens and releases the corresponding
     *         ERC-3475 position units.
     *
     * @param tokenId ERC-1155 token ID to unwrap.
     * @param amount Quantity to burn and release.
     * @param recipient Address receiving the released ERC-3475 units.
     *
     * @dev Partial unwrapping is allowed. The position becomes inactive when
     *      all wrapped units have been released.
     */
    function unwrap(
        uint256 tokenId,
        uint256 amount,
        address recipient
    ) external nonReentrant {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }

        if (amount == 0) {
            revert InvalidAmount();
        }

        WrappedPosition storage wrappedPosition = _positions[tokenId];

        if (!wrappedPosition.active) {
            revert PositionNotFound(tokenId);
        }

        uint256 holderBalance = balanceOf(
            msg.sender,
            tokenId
        );

        if (holderBalance < amount) {
            revert InsufficientWrappedBalance(
                tokenId,
                amount,
                holderBalance
            );
        }

        if (wrappedPosition.amount < amount) {
            revert InsufficientWrappedBalance(
                tokenId,
                amount,
                wrappedPosition.amount
            );
        }

        /*
         * Burn the ERC-1155 representation.
         */
        _burn(
            msg.sender,
            tokenId,
            amount
        );

        wrappedPosition.amount -= amount;

        if (wrappedPosition.amount == 0) {
            wrappedPosition.active = false;
        }

        ERC3475.Transaction[]
            memory transactions =
                new ERC3475.Transaction[](1);

        transactions[0] = ERC3475.Transaction({
            classId: wrappedPosition.classId,
            nonceId: wrappedPosition.nonceId,
            amount: amount
        });

        /*
         * Release the underlying ERC-3475 asset.
         */
        underlying.transferFrom(
            address(this),
            recipient,
            transactions
        );

        emit EAssetUnwrapped(
            tokenId,
            recipient,
            amount
        );
    }

    // -------------------------------------------------------------------------
    // Confidential record management
    // -------------------------------------------------------------------------

    /**
     * @notice Replaces the encrypted information associated with a token.
     *
     * @dev Only the position record manager or contract owner can update it.
     */
    function updateConfidentialRecord(
        uint256 tokenId,
        InEaddress calldata beneficialOwner,
        InEuint128 calldata legalHashHigh,
        InEuint128 calldata legalHashLow,
        InEuint128 calldata corporateHashHigh,
        InEuint128 calldata corporateHashLow,
        InEuint128 calldata ownershipRefHigh,
        InEuint128 calldata ownershipRefLow
    ) external onlyRecordManager(tokenId) {
        _storeConfidentialRecord(
            tokenId,
            beneficialOwner,
            legalHashHigh,
            legalHashLow,
            corporateHashHigh,
            corporateHashLow,
            ownershipRefHigh,
            ownershipRefLow,
            msg.sender
        );
    }

    /**
     * @notice Grants a viewer CoFHE ACL access to all encrypted fields.
     *
     * @param tokenId ERC-1155 position token ID.
     * @param viewer Address receiving access.
     *
     * @dev Granting ACL access does not automatically decrypt information.
     *      The viewer must still use the appropriate CoFHE sealing or
     *      decryption flow.
     */
    function grantConfidentialViewer(
        uint256 tokenId,
        address viewer
    ) external onlyRecordManager(tokenId) {
        if (viewer == address(0)) {
            revert ZeroAddress();
        }

        _allowRecord(
            _confidentialRecords[tokenId],
            viewer
        );

        emit ConfidentialViewerGranted(
            tokenId,
            viewer
        );
    }

    /**
     * @notice Transfers confidential-record management authority.
     *
     * @param tokenId ERC-1155 token ID.
     * @param newManager New confidential record manager.
     */
    function transferRecordManager(
        uint256 tokenId,
        address newManager
    ) external onlyRecordManager(tokenId) {
        if (newManager == address(0)) {
            revert ZeroAddress();
        }

        WrappedPosition storage wrappedPosition = _positions[tokenId];

        address previousManager = wrappedPosition.recordManager;

        wrappedPosition.recordManager = newManager;

        /*
         * Grant the new manager ACL access to all existing ciphertexts.
         */
        _allowRecord(
            _confidentialRecords[tokenId],
            newManager
        );

        emit RecordManagerTransferred(
            tokenId,
            previousManager,
            newManager
        );
    }

    /**
     * @notice Returns the encrypted ciphertext handles for a position.
     *
     * @dev Returning ciphertext handles does not grant permission to decrypt
     *      them. CoFHE ACL authorization is enforced separately.
     */
    function confidentialRecord(
        uint256 tokenId
    ) external view returns (ConfidentialRecord memory record) {
        if (!_positions[tokenId].active) {
            revert PositionNotFound(tokenId);
        }

        record = _confidentialRecords[tokenId];
    }

    // -------------------------------------------------------------------------
    // SchrodingerHook market integration
    // -------------------------------------------------------------------------

    /**
     * @notice Sets the authorized SchrodingerHook contract.
     *
     * @dev The hook is automatically registered as an approved pool operator.
     */
    function setSchrodingerHook(
        address hook
    ) external onlyOwner {
        if (hook == address(0)) {
            revert ZeroAddress();
        }

        schrodingerHook = hook;
        approvedPoolOperators[hook] = true;

        emit SchrodingerHookSet(hook);
        emit PoolOperatorSet(hook, true);
    }

    /**
     * @notice Approves or removes a Schrodinger pool component.
     *
     * @param operator Pool, vault, hook, adapter, or settlement component.
     * @param approved Whether the component is approved.
     */
    function setPoolOperator(
        address operator,
        bool approved
    ) external onlyOwner {
        if (operator == address(0)) {
            revert ZeroAddress();
        }

        approvedPoolOperators[operator] = approved;

        emit PoolOperatorSet(
            operator,
            approved
        );
    }

    /**
     * @notice Grants a registered Schrodinger market component access to the
     *         token's encrypted information.
     *
     * @param tokenId ERC-1155 market token ID.
     * @param poolComponent Approved market component receiving ACL access.
     */
    function grantPoolAccess(
        uint256 tokenId,
        address poolComponent
    ) external onlyOwner {
        if (!approvedPoolOperators[poolComponent]) {
            revert Unauthorized();
        }

        if (!_positions[tokenId].active) {
            revert PositionNotFound(tokenId);
        }

        _allowRecord(
            _confidentialRecords[tokenId],
            poolComponent
        );

        emit ConfidentialViewerGranted(
            tokenId,
            poolComponent
        );
    }

    /**
     * @notice Returns public information for a wrapped position.
     */
    function position(
        uint256 tokenId
    ) external view returns (WrappedPosition memory wrappedPosition) {
        wrappedPosition = _positions[tokenId];

        if (!wrappedPosition.active) {
            revert PositionNotFound(tokenId);
        }
    }

    /**
     * @notice Returns whether a token is eligible to be used in a
     *         Schrodinger market pool.
     */
    function isSchrodingerEligible(
        uint256 tokenId
    ) external view returns (bool) {
        WrappedPosition memory wrappedPosition = _positions[tokenId];

        return (
            wrappedPosition.active
                && wrappedPosition.amount > 0
        );
    }

    /**
     * @notice Returns the underlying ERC-3475 asset represented by a token.
     */
    function underlyingAsset(
        uint256 tokenId
    )
        external
        view
        returns (
            uint256 classId,
            uint256 nonceId,
            uint256 amount
        )
    {
        WrappedPosition memory wrappedPosition = _positions[tokenId];

        if (!wrappedPosition.active) {
            revert PositionNotFound(tokenId);
        }

        return (
            wrappedPosition.classId,
            wrappedPosition.nonceId,
            wrappedPosition.amount
        );
    }

    // -------------------------------------------------------------------------
    // ERC-1155 metadata administration
    // -------------------------------------------------------------------------

    /**
     * @notice Updates the ERC-1155 base metadata URI.
     */
    function setURI(
        string calldata newURI
    ) external onlyOwner {
        _setURI(newURI);
    }

    // -------------------------------------------------------------------------
    // Internal confidential-record functions
    // -------------------------------------------------------------------------

    /**
     * @notice Converts encrypted input values into on-chain CoFHE handles,
     *         stores them, and assigns persistent access permissions.
     */
    function _storeConfidentialRecord(
        uint256 tokenId,
        InEaddress calldata beneficialOwnerInput,
        InEuint128 calldata legalHashHighInput,
        InEuint128 calldata legalHashLowInput,
        InEuint128 calldata corporateHashHighInput,
        InEuint128 calldata corporateHashLowInput,
        InEuint128 calldata ownershipRefHighInput,
        InEuint128 calldata ownershipRefLowInput,
        address initialViewer
    ) internal {
        ConfidentialRecord storage record =
            _confidentialRecords[tokenId];

        record.beneficialOwner =
            FHE.asEaddress(beneficialOwnerInput);

        record.legalAgreementHashHigh =
            FHE.asEuint128(legalHashHighInput);

        record.legalAgreementHashLow =
            FHE.asEuint128(legalHashLowInput);

        record.corporateDocumentHashHigh =
            FHE.asEuint128(corporateHashHighInput);

        record.corporateDocumentHashLow =
            FHE.asEuint128(corporateHashLowInput);

        record.ownershipReferenceHigh =
            FHE.asEuint128(ownershipRefHighInput);

        record.ownershipReferenceLow =
            FHE.asEuint128(ownershipRefLowInput);

        /*
         * Preserve contract-level access for future transactions.
         */
        _allowRecordThis(record);

        /*
         * Grant the initial record manager access.
         */
        _allowRecord(
            record,
            initialViewer
        );

        /*
         * Automatically grant the SchrodingerHook access when configured.
         */
        if (schrodingerHook != address(0)) {
            _allowRecord(
                record,
                schrodingerHook
            );
        }

        emit ConfidentialRecordUpdated(
            tokenId,
            initialViewer
        );
    }

    /**
     * @notice Grants this contract persistent access to each encrypted value.
     */
    function _allowRecordThis(
        ConfidentialRecord storage record
    ) internal {
        FHE.allowThis(
            record.beneficialOwner
        );

        FHE.allowThis(
            record.legalAgreementHashHigh
        );

        FHE.allowThis(
            record.legalAgreementHashLow
        );

        FHE.allowThis(
            record.corporateDocumentHashHigh
        );

        FHE.allowThis(
            record.corporateDocumentHashLow
        );

        FHE.allowThis(
            record.ownershipReferenceHigh
        );

        FHE.allowThis(
            record.ownershipReferenceLow
        );
    }

    /**
     * @notice Grants a viewer persistent access to each encrypted value.
     */
    function _allowRecord(
        ConfidentialRecord storage record,
        address viewer
    ) internal {
        FHE.allow(
            record.beneficialOwner,
            viewer
        );

        FHE.allow(
            record.legalAgreementHashHigh,
            viewer
        );

        FHE.allow(
            record.legalAgreementHashLow,
            viewer
        );

        FHE.allow(
            record.corporateDocumentHashHigh,
            viewer
        );

        FHE.allow(
            record.corporateDocumentHashLow,
            viewer
        );

        FHE.allow(
            record.ownershipReferenceHigh,
            viewer
        );

        FHE.allow(
            record.ownershipReferenceLow,
            viewer
        );
    }
}