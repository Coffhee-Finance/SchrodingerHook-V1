// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title eMemeToken
 * @author Coffhee Finance
 *
 * @notice
 * eMeme is Coffhee Finance's dual-mode meme token.
 *
 * It supports:
 *
 *  1. ERC-20
 *     - Public balances
 *     - Public transfers
 *     - Public allowances
 *
 *  2. ERC-7984
 *     - Confidential balances
 *     - Encrypted transfer amounts
 *     - Confidential transfers using Fhenix CoFHE
 *
 * Users may therefore hold eMEME publicly or confidentially.
 *
 * The eMeme represents a cup featuring the Coffhee logo.
 *
 * Holder-only encrypted message:
 *
 * "Coffhee Tokens will be airdropped in June 2027"
 *
 * IMPORTANT:
 *
 * The production encrypted message should NOT be stored as plaintext
 * in contract storage.
 *
 * The contract instead stores:
 *
 *  - a commitment/hash identifying the official message
 *  - a URI pointing to the encrypted message payload
 *
 * The frontend uses Fhenix CoFHE permissions/decryption to reveal
 * the encrypted content to an authorized eMEME holder.
 */

import {
    ERC20Confidential
} from
    "fhenix-confidential-contracts/contracts/ERC20Confidential/ERC20Confidential.sol";

import {
    Ownable
} from
    "@openzeppelin/contracts/access/Ownable.sol";


contract eMemeToken is ERC20Confidential, Ownable {

    /*//////////////////////////////////////////////////////////////
                              TOKEN CONFIG
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_SUPPLY =
        1_000_000_000 ether;


    /*//////////////////////////////////////////////////////////////
                          eMEME METADATA
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Metadata for the Coffhee cup image.
     *
     * Example:
     *
     * ipfs://<CID>/ememe.json
     *
     * Example JSON:
     *
     * {
     *   "name": "Coffhee eMeme",
     *   "symbol": "eMEME",
     *   "description":
     *       "Coffhee Finance confidential meme token",
     *   "image":
     *       "ipfs://<CID>/coffhee-cup.png"
     * }
     */
    string public tokenURI;


    /*//////////////////////////////////////////////////////////////
                       ENCRYPTED HOLDER MESSAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Cryptographic commitment to the official holder message.
     *
     * Message:
     *
     * "Coffhee Tokens will be airdropped in June 2027"
     *
     * For the final deployment, calculate this hash off-chain and
     * pass only the bytes32 value into the constructor.
     */
    bytes32 public immutable HOLDER_MESSAGE_COMMITMENT;

    /**
     * @notice
     * URI pointing to the encrypted message payload.
     *
     * Example:
     *
     * ipfs://<CID>/coffhee-holder-message.enc
     *
     * The file itself MUST contain encrypted data.
     */
    string private _encryptedMessageURI;


    /*//////////////////////////////////////////////////////////////
                         PUBLIC SUPPLY TRACKING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Amount minted into the public ERC-20 ledger through the
     * owner mint function.
     *
     * This is NOT the user's confidential balance.
     */
    uint256 public publicMintedSupply;


    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event PublicTokensMinted(
        address indexed recipient,
        uint256 amount
    );

    event TokenURIUpdated(
        string previousURI,
        string newURI
    );

    event EncryptedMessageURIUpdated(
        string previousURI,
        string newURI
    );


    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();

    error ZeroAmount();

    error MaxSupplyExceeded();

    error NotEMemeHolder();

    error EmptyURI();


    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param initialOwner
     * Owner/admin of the eMeme contract.
     *
     * @param initialPublicSupply
     * Initial supply minted into the PUBLIC ERC-20 ledger.
     *
     * @param initialTokenURI
     * Metadata URI containing the Coffhee cup image.
     *
     * @param encryptedMessageURI_
     * URI containing the encrypted holder message.
     *
     * @param messageCommitment_
     * keccak256 hash of:
     *
     * "Coffhee Tokens will be airdropped in June 2027"
     *
     * Generate this value off-chain before deployment so the
     * plaintext message does not have to appear in verified
     * production bytecode/source configuration.
     */
    constructor(
        address initialOwner,
        uint256 initialPublicSupply,
        string memory initialTokenURI,
        string memory encryptedMessageURI_,
        bytes32 messageCommitment_
    )
        ERC20Confidential(
            "Coffhee eMeme",
            "eMEME"
        )
        Ownable(initialOwner)
    {
        if (initialOwner == address(0)) {
            revert ZeroAddress();
        }

        if (initialPublicSupply > MAX_SUPPLY) {
            revert MaxSupplyExceeded();
        }

        if (bytes(initialTokenURI).length == 0) {
            revert EmptyURI();
        }

        if (bytes(encryptedMessageURI_).length == 0) {
            revert EmptyURI();
        }

        tokenURI =
            initialTokenURI;

        _encryptedMessageURI =
            encryptedMessageURI_;

        HOLDER_MESSAGE_COMMITMENT =
            messageCommitment_;

        /*
         * ERC20Confidential provides the host ERC-20 ledger.
         *
         * _mint() therefore creates PUBLIC ERC-20 eMEME.
         *
         * Confidential ERC-7984 balances are handled separately
         * through the ERC20Confidential confidential interface.
         */
        if (initialPublicSupply > 0) {

            publicMintedSupply =
                initialPublicSupply;

            _mint(
                initialOwner,
                initialPublicSupply
            );

            emit PublicTokensMinted(
                initialOwner,
                initialPublicSupply
            );
        }
    }


    /*//////////////////////////////////////////////////////////////
                        PUBLIC ERC-20 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Mint PUBLIC ERC-20 eMEME.
     *
     * These tokens use the normal ERC-20 ledger.
     *
     * Public users can use inherited ERC-20 functions including:
     *
     * transfer()
     * transferFrom()
     * approve()
     * allowance()
     * balanceOf()
     */
    function mintPublic(
        address recipient,
        uint256 amount
    )
        external
        onlyOwner
    {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }

        if (amount == 0) {
            revert ZeroAmount();
        }

        if (
            publicMintedSupply + amount >
            MAX_SUPPLY
        ) {
            revert MaxSupplyExceeded();
        }

        publicMintedSupply +=
            amount;

        _mint(
            recipient,
            amount
        );

        emit PublicTokensMinted(
            recipient,
            amount
        );
    }


    /*//////////////////////////////////////////////////////////////
                    ERC-7984 CONFIDENTIAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * ERC20Confidential supplies the ERC-7984 confidential API.
     *
     * The inherited confidential interface includes functionality
     * for confidential balances and encrypted transfers.
     *
     * Examples include:
     *
     * confidentialTransfer(...)
     *
     * confidentialTransferFrom(...)
     *
     * confidentialTransferAndCall(...)
     *
     * setOperator(...)
     *
     * isOperator(...)
     *
     * The transfer amount is represented by an encrypted FHE
     * ciphertext rather than a public uint256 amount.
     *
     * We intentionally DO NOT create our own second confidential
     * balance mapping here. ERC20Confidential already maintains
     * the ERC-7984 confidential ledger.
     */


    /*//////////////////////////////////////////////////////////////
                       HOLDER ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Returns whether an account has an eMEME position.
     *
     * IMPORTANT:
     *
     * ERC20Confidential uses balance indicators so applications
     * can determine whether confidential balance activity exists
     * without exposing the true confidential amount.
     *
     * This function must therefore only be treated as an ACCESS /
     * MEMBERSHIP signal.
     *
     * It does NOT disclose the user's confidential balance.
     */
    function isEMemeHolder(
        address account
    )
        public
        view
        returns (bool)
    {
        if (account == address(0)) {
            return false;
        }

        return balanceOf(account) > 0;
    }


    /*//////////////////////////////////////////////////////////////
                    ENCRYPTED MESSAGE ACCESS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Returns the URI containing the encrypted Coffhee message.
     *
     * Only an address recognized as an eMEME holder may request
     * the URI through this function.
     *
     * IMPORTANT:
     *
     * Returning a URI from a Solidity view function is NOT itself
     * cryptographic privacy.
     *
     * Blockchain state can be inspected directly.
     *
     * Therefore the object stored at the URI MUST itself be
     * encrypted.
     *
     * The frontend should use Fhenix / CoFHE authorization before
     * decrypting the payload.
     */
    function encryptedHolderMessageURI()
        external
        view
        returns (string memory)
    {
        if (!isEMemeHolder(msg.sender)) {
            revert NotEMemeHolder();
        }

        return _encryptedMessageURI;
    }


    /**
     * @notice
     * Verify that a decrypted message corresponds to the official
     * Coffhee holder message.
     *
     * Official message:
     *
     * "Coffhee Tokens will be airdropped in June 2027"
     *
     * @param plaintext
     * Decrypted plaintext supplied by the application.
     */
    function verifyHolderMessage(
        string calldata plaintext
    )
        external
        view
        returns (bool)
    {
        return
            keccak256(
                bytes(plaintext)
            )
            ==
            HOLDER_MESSAGE_COMMITMENT;
    }


    /*//////////////////////////////////////////////////////////////
                         ADMIN: TOKEN IMAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Update the eMeme metadata URI.
     */
    function setTokenURI(
        string calldata newTokenURI
    )
        external
        onlyOwner
    {
        if (bytes(newTokenURI).length == 0) {
            revert EmptyURI();
        }

        string memory previousURI =
            tokenURI;

        tokenURI =
            newTokenURI;

        emit TokenURIUpdated(
            previousURI,
            newTokenURI
        );
    }


    /*//////////////////////////////////////////////////////////////
                       ADMIN: SECRET MESSAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice
     * Change the encrypted payload location.
     *
     * This changes WHERE the ciphertext is stored.
     *
     * It does not expose or decrypt the message.
     */
    function setEncryptedMessageURI(
        string calldata newURI
    )
        external
        onlyOwner
    {
        if (bytes(newURI).length == 0) {
            revert EmptyURI();
        }

        string memory previousURI =
            _encryptedMessageURI;

        _encryptedMessageURI =
            newURI;

        emit EncryptedMessageURIUpdated(
            previousURI,
            newURI
        );
    }


    /*//////////////////////////////////////////////////////////////
                         PROTOCOL INFORMATION
    //////////////////////////////////////////////////////////////*/

    function description()
        external
        pure
        returns (string memory)
    {
        return
            "Coffhee eMeme is a dual ERC-20 and ERC-7984 confidential meme token.";
    }


    function tokenType()
        external
        pure
        returns (string memory)
    {
        return
            "ERC-20 + ERC-7984";
    }


    function privacyProtocol()
        external
        pure
        returns (string memory)
    {
        return
            "Fhenix CoFHE";
    }


    function ecosystem()
        external
        pure
        returns (string memory)
    {
        return
            "Coffhee Finance";
    }
}