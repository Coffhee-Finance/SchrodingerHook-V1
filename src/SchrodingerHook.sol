// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    FHE,
    ebool,
    euint64,
    InEbool,
    InEuint64
} from "cofhe-contracts/FHE.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {
    SwapParams,
    ModifyLiquidityParams
} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {
    BalanceDelta,
    BalanceDeltaLibrary
} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {
    IPermissionsAdapter
} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";

import {
    IPermissionsAdapterFactory
} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";

import {
    IAllowlistChecker
} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";

import {
    PermissionFlag,
    PermissionFlags
} from "@uniswap/v4-periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";


interface IERC7984Minimal is IERC165 {
    function confidentialBalanceOf(
        address account
    )
        external
        view
        returns (euint64);
}


interface IEncryptedERC1155 is IERC165, IERC1155 {
    function confidentialBalanceOf(
        address account,
        uint256 tokenId
    )
        external
        view
        returns (euint64);
}


interface IERC3475Backing is IERC165 {
    function getProgress(
        uint256 classId,
        uint256 nonceId
    )
        external
        view
        returns (
            uint256 progressAchieved,
            uint256 progressRemaining
        );
}

// ArbSepolia Address: 0x05D0E9Df9e6FB6e6348290cbF2acE40142B568c0


contract SchrodingerHook is
    IHooks,
    Ownable,
    ReentrancyGuard,
    IUnlockCallback,
    IERC1155Receiver
{
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable poolManager;

    uint8 public constant MAX_ASSETS = 8;
    uint64 public constant BPS = 10_000;

    bytes4 public constant ERC7984_INTERFACE_ID =
        0x4958f2a4;

    bytes4 public constant ENCRYPTED_1155_INTERFACE_ID =
        type(IEncryptedERC1155).interfaceId;

    bytes4 public constant ERC3475_BACKING_INTERFACE_ID =
        type(IERC3475Backing).interfaceId;

    uint256 public constant CAP_BEFORE_SWAP =
        1 << 0;

    uint256 public constant CAP_AFTER_SWAP =
        1 << 1;

    uint256 public constant CAP_TEMPORARY_LIQUIDITY =
        1 << 2;

    uint256 public constant CAP_PERSISTENT_LIQUIDITY =
        1 << 3;

    uint256 public constant CAP_EXTERNAL_HEDGE =
        1 << 4;

    uint256 public constant CAP_EASSET_REBALANCE =
        1 << 5;

    uint256 public constant CAP_BOND_SETTLEMENT =
        1 << 6;

    uint256 public constant CAP_ORACLE_REFRESH =
        1 << 8;

    enum MarketType {
        UNSET,
        ETOKEN,
        EASSET
    }

    enum AccessMode {
        PERMISSIONLESS,
        PERMISSIONED
    }

    enum StrategyKind {
        CUSTOM,
        DARKPOOL_JIT,
        PRIVATE_TWAMM,
        TREASURY_REBALANCE,
        HEDGE_ONLY,
        BOND_LADDER,
        MATURITY_ROLLOVER
    }

    enum ExecutionMode {
        TEMPORARY,
        PERSISTENT,
        HEDGE_ONLY,
        SETTLEMENT_ONLY
    }

    enum UnlockAction {
        MODIFY_LIQUIDITY
    }

    struct PlanInput {
        MarketType marketType;
        StrategyKind strategyKind;
        ExecutionMode executionMode;
        uint256 capabilities;
        InEuint64[] encryptedTargets;
        InEuint64 encryptedRebalanceThresholdBps;
        InEuint64 encryptedMaximumAllocation;
        InEuint64 encryptedHedgeIntensityBps;
        InEuint64 encryptedVolatilityBps;
        InEuint64 encryptedFeeAprBps;
        InEuint64 encryptedTimingSeed;
        InEbool encryptedComplianceEnabled;
    }

    struct ExecutionPlan {
        address owner;
        MarketType marketType;
        StrategyKind strategyKind;
        ExecutionMode executionMode;
        uint256 capabilities;
        bool active;
        bool armed;
        uint8 assetCount;
        uint64 lastSignalAt;

        mapping(uint8 => euint64) targetBps;
        mapping(uint8 => euint64) exposure;
        mapping(uint8 => euint64) drift;
        mapping(uint8 => euint64) lastRebalanceDelta;

        euint64 rebalanceThresholdBps;
        euint64 maximumAllocation;
        euint64 hedgeIntensityBps;
        euint64 volatilityBps;
        euint64 feeAprBps;
        euint64 timingSeed;

        ebool complianceEnabled;
        ebool lastExecutionApproved;
    }

    struct ETokenMarket {
        bool initialized;
        bool paused;
        bytes32 planId;
        uint8 assetIndex;
        AccessMode accessMode;
        address token0;
        address token1;
        int24 defaultTickLower;
        int24 defaultTickUpper;
        bytes32 positionSalt;
    }

    struct EAssetMarket {
        bool initialized;
        bool paused;
        bytes32 planId;
        uint8 assetIndex;
        AccessMode accessMode;
        IAllowlistChecker allowlistChecker;
        address positionToken;
        uint256 positionTokenId;
        address backingBond;
        uint256 bondClassId;
        uint256 bondNonceId;
        address settlementEToken;
        euint64 encryptedInventory;
        euint64 encryptedCollateral;
        euint64 encryptedLastDelta;
    }

    struct LiquidityExecution {
        UnlockAction action;
        bytes32 planId;
        bytes32 executionId;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 positionSalt;
    }

    mapping(bytes32 => ExecutionPlan)
        private _plans;

    mapping(PoolId => ETokenMarket)
        public eTokenMarkets;

    mapping(bytes32 => EAssetMarket)
        private _eAssetMarkets;

    mapping(address => bool)
        public approvedEToken;

    mapping(address => bool)
        public approvedEAssetToken;

    mapping(address => bool)
        public approvedBondContract;

    mapping(address => bool)
        public approvedProtocolModule;

    mapping(bytes32 => bool)
        public processedExecutions;

    mapping(bytes32 => bool)
        public oracleDegraded;

    mapping(bytes32 => bytes32)
        public eAssetMarketByPosition;

    IPermissionsAdapterFactory
        public permissionsAdapterFactory;

    bool public globalPaused;

    uint256 private _planNonce;

    event PlanCreated(
        bytes32 indexed planId,
        address indexed owner,
        MarketType indexed marketType,
        StrategyKind strategyKind,
        ExecutionMode executionMode,
        uint256 capabilities
    );

    event PlanArmed(
        bytes32 indexed planId,
        bool armed
    );

    event PlanDeactivated(
        bytes32 indexed planId
    );

    event ETokenMarketCreated(
        PoolId indexed poolId,
        bytes32 indexed planId,
        address token0,
        address token1,
        uint8 assetIndex
    );

    event EAssetMarketCreated(
        bytes32 indexed marketId,
        bytes32 indexed planId,
        address positionToken,
        uint256 positionTokenId,
        address backingBond,
        address settlementEToken
    );

    event PrivateRebalanceEvaluated(
        bytes32 indexed planId,
        bytes32 indexed marketRef,
        MarketType marketType
    );

    event ETokenRebalanceExecuted(
        PoolId indexed poolId,
        bytes32 indexed planId,
        bytes32 indexed executionId,
        int256 liquidityDelta,
        int128 amount0,
        int128 amount1
    );

    event EAssetRebalanceRecorded(
        bytes32 indexed marketId,
        bytes32 indexed planId,
        bytes32 indexed executionId
    );

    event OracleSignalReceived(
        bytes32 indexed marketRef,
        bytes32 indexed planId,
        bytes32 indexed queryId,
        uint256 value,
        uint256 timestamp
    );

    event ProtocolModuleSet(
        address indexed module,
        bool approved
    );

    event ETokenApprovalSet(
        address indexed token,
        bool approved
    );

    event EAssetTokenApprovalSet(
        address indexed token,
        bool approved
    );

    event BondApprovalSet(
        address indexed bond,
        bool approved
    );

    event PermissionsAdapterFactorySet(
        address indexed factory
    );

    event ETokenAccessModeSet(
        PoolId indexed poolId,
        AccessMode indexed accessMode,
        address token0,
        address token1
    );

    event EAssetAccessModeSet(
        bytes32 indexed marketId,
        AccessMode indexed accessMode,
        address indexed allowlistChecker
    );

    event PermissionedSwapObserved(
        PoolId indexed poolId,
        address indexed approvedWrapper,
        address token0,
        address token1
    );

    error InvalidAddress();
    error InvalidPlan();
    error InvalidMarket();
    error InvalidAssetCount();
    error InvalidAssetIndex();
    error InvalidExecutionId();
    error ExecutionAlreadyProcessed();
    error OnlyProtocolModule();
    error OnlyPoolManager();
    error WrongMarketType();
    error MixedAssetStandards();
    error PlanInactive();
    error PlanNotArmed();
    error CapabilityDisabled();
    error MarketPaused();
    error GlobalPause();
    error NativeTokenNotAllowed();
    error NonHybridEToken();
    error NonEncryptedERC1155();
    error NonERC3475Backing();
    error UnapprovedToken();
    error InvalidTicks();
    error InvalidLiquidityDelta();
    error NotPlanOwner();
    error PermissionedFactoryNotConfigured();
    error PermissionedAdapterRequired();

    error UnverifiedPermissionsAdapter(
        address adapter
    );

    error PermissionedWrapperNotAllowed(
        address adapter,
        address wrapper
    );

    error PermissionedSwappingDisabled(
        address adapter
    );

    error InvalidAllowlistChecker(
        address checker
    );

    error PermissionDenied(
        address account,
        address asset,
        bytes2 requiredPermission
    );

    modifier onlyProtocolModule() {
        if (!approvedProtocolModule[msg.sender]) {
            revert OnlyProtocolModule();
        }

        _;
    }

    modifier onlyPlanOwner(
        bytes32 planId
    ) {
        ExecutionPlan storage plan =
            _plans[planId];

        if (plan.owner == address(0)) {
            revert InvalidPlan();
        }

        if (plan.owner != msg.sender) {
            revert NotPlanOwner();
        }

        _;
    }

    modifier onlyPoolManager() {
        if (
            msg.sender
                != address(poolManager)
        ) {
            revert OnlyPoolManager();
        }

        _;
    }

    constructor(
        IPoolManager manager,
        address initialOwner
    )
        Ownable(initialOwner)
    {
        if (
            address(manager) == address(0)
                || initialOwner == address(0)
        ) {
            revert InvalidAddress();
        }

        poolManager =
            manager;

        approvedProtocolModule[
            initialOwner
        ] = true;

        emit ProtocolModuleSet(
            initialOwner,
            true
        );
    }

    function getHookPermissions()
        public
        pure
        returns (
            Hooks.Permissions memory
        )
    {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                    UNISWAP V4 CALLBACKS
    //////////////////////////////////////////////////////////////*/

    function beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160
    )
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        _beforeInitializePermissionCheck(
            sender,
            key
        );

        return
            IHooks
                .beforeInitialize
                .selector;
    }

    function afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    )
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        return
            IHooks
                .afterInitialize
                .selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        _requirePermissionedLiquidityWrapper(
            sender,
            key
        );

        return
            IHooks
                .beforeAddLiquidity
                .selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (
            bytes4,
            BalanceDelta
        )
    {
        return (
            IHooks
                .afterAddLiquidity
                .selector,
            BalanceDeltaLibrary
                .ZERO_DELTA
        );
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        return
            IHooks
                .beforeRemoveLiquidity
                .selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (
            bytes4,
            BalanceDelta
        )
    {
        return (
            IHooks
                .afterRemoveLiquidity
                .selector,
            BalanceDeltaLibrary
                .ZERO_DELTA
        );
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    )
        external
        override
        onlyPoolManager
        returns (
            bytes4,
            BeforeSwapDelta,
            uint24
        )
    {
        return _beforeSwap(
            sender,
            key,
            params,
            hookData
        );
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    )
        external
        override
        onlyPoolManager
        returns (
            bytes4,
            int128
        )
    {
        return _afterSwap(
            sender,
            key,
            params,
            delta,
            hookData
        );
    }

    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        return
            IHooks
                .beforeDonate
                .selector;
    }

    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        return
            IHooks
                .afterDonate
                .selector;
    }

    /*//////////////////////////////////////////////////////////////
                               ADMIN
    //////////////////////////////////////////////////////////////*/

    function setProtocolModule(
        address module,
        bool approved
    )
        external
        onlyOwner
    {
        if (module == address(0)) {
            revert InvalidAddress();
        }

        approvedProtocolModule[
            module
        ] = approved;

        emit ProtocolModuleSet(
            module,
            approved
        );
    }

    function setPermissionsAdapterFactory(
        address factory
    )
        external
        onlyOwner
    {
        if (factory == address(0)) {
            revert InvalidAddress();
        }

        permissionsAdapterFactory =
            IPermissionsAdapterFactory(
                factory
            );

        emit PermissionsAdapterFactorySet(
            factory
        );
    }

    function setApprovedEToken(
        address token,
        bool approved
    )
        external
        onlyOwner
    {
        if (token == address(0)) {
            revert InvalidAddress();
        }

        if (approved) {
            _requireHybridEToken(
                token
            );
        }

        approvedEToken[token] =
            approved;

        emit ETokenApprovalSet(
            token,
            approved
        );
    }

    function setApprovedEAssetToken(
        address token,
        bool approved
    )
        external
        onlyOwner
    {
        if (token == address(0)) {
            revert InvalidAddress();
        }

        if (approved) {
            _requireEncrypted1155(
                token
            );
        }

        approvedEAssetToken[token] =
            approved;

        emit EAssetTokenApprovalSet(
            token,
            approved
        );
    }

    function setApprovedBondContract(
        address bond,
        bool approved
    )
        external
        onlyOwner
    {
        if (bond == address(0)) {
            revert InvalidAddress();
        }

        if (approved) {
            _requireERC3475(
                bond
            );
        }

        approvedBondContract[bond] =
            approved;

        emit BondApprovalSet(
            bond,
            approved
        );
    }

    function setGlobalPaused(
        bool paused
    )
        external
        onlyOwner
    {
        globalPaused =
            paused;
    }

    /*//////////////////////////////////////////////////////////////
                       INVENTORY / CUSTODY
    //////////////////////////////////////////////////////////////*/

    function depositEToken(
        address token,
        uint256 amount
    )
        external
        nonReentrant
    {
        if (!approvedEToken[token]) {
            revert UnapprovedToken();
        }

        _requireHybridEToken(
            token
        );

        IERC20(token)
            .safeTransferFrom(
                msg.sender,
                address(this),
                amount
            );
    }

    function withdrawEToken(
        address token,
        address recipient,
        uint256 amount
    )
        external
        onlyOwner
        nonReentrant
    {
        if (recipient == address(0)) {
            revert InvalidAddress();
        }

        IERC20(token)
            .safeTransfer(
                recipient,
                amount
            );
    }

    function depositEAsset(
        address positionToken,
        uint256 tokenId,
        uint256 amount,
        bytes calldata data
    )
        external
        nonReentrant
    {
        if (
            !approvedEAssetToken[
                positionToken
            ]
        ) {
            revert UnapprovedToken();
        }

        bytes32 positionRef =
            keccak256(
                abi.encode(
                    positionToken,
                    tokenId
                )
            );

        bytes32 marketId =
            eAssetMarketByPosition[
                positionRef
            ];

        if (
            marketId
                != bytes32(0)
        ) {
            _requireEAssetPermission(
                marketId,
                msg.sender,
                PermissionFlags
                    .LIQUIDITY_ALLOWED
            );
        }

        IERC1155(positionToken)
            .safeTransferFrom(
                msg.sender,
                address(this),
                tokenId,
                amount,
                data
            );
    }

    function withdrawEAsset(
        address positionToken,
        address recipient,
        uint256 tokenId,
        uint256 amount,
        bytes calldata data
    )
        external
        onlyOwner
        nonReentrant
    {
        if (recipient == address(0)) {
            revert InvalidAddress();
        }

        IERC1155(positionToken)
            .safeTransferFrom(
                address(this),
                recipient,
                tokenId,
                amount,
                data
            );
    }

    /*//////////////////////////////////////////////////////////////
                        CONFIDENTIAL PLANS
    //////////////////////////////////////////////////////////////*/

    function createPlan(
        PlanInput calldata input
    )
        external
        returns (bytes32 planId)
    {
        uint256 len =
            input
                .encryptedTargets
                .length;

        if (
            input.marketType
                == MarketType.UNSET
        ) {
            revert WrongMarketType();
        }

        if (
            len == 0
                || len > MAX_ASSETS
        ) {
            revert InvalidAssetCount();
        }

        planId =
            keccak256(
                abi.encode(
                    msg.sender,
                    block.chainid,
                    address(this),
                    ++_planNonce
                )
            );

        ExecutionPlan storage plan =
            _plans[planId];

        plan.owner =
            msg.sender;

        plan.marketType =
            input.marketType;

        plan.strategyKind =
            input.strategyKind;

        plan.executionMode =
            input.executionMode;

        plan.capabilities =
            input.capabilities;

        plan.active = true;
        plan.armed = false;
        plan.assetCount =
            uint8(len);

        plan.rebalanceThresholdBps =
            FHE.asEuint64(
                input
                    .encryptedRebalanceThresholdBps
            );

        plan.maximumAllocation =
            FHE.asEuint64(
                input
                    .encryptedMaximumAllocation
            );

        plan.hedgeIntensityBps =
            FHE.asEuint64(
                input
                    .encryptedHedgeIntensityBps
            );

        plan.volatilityBps =
            FHE.asEuint64(
                input
                    .encryptedVolatilityBps
            );

        plan.feeAprBps =
            FHE.asEuint64(
                input
                    .encryptedFeeAprBps
            );

        plan.timingSeed =
            FHE.asEuint64(
                input
                    .encryptedTimingSeed
            );

        plan.complianceEnabled =
            FHE.asEbool(
                input
                    .encryptedComplianceEnabled
            );

        _allowOwnerAndContract(
            plan.rebalanceThresholdBps
        );

        _allowOwnerAndContract(
            plan.maximumAllocation
        );

        _allowOwnerAndContract(
            plan.hedgeIntensityBps
        );

        _allowOwnerAndContract(
            plan.volatilityBps
        );

        _allowOwnerAndContract(
            plan.feeAprBps
        );

        _allowOwnerAndContract(
            plan.timingSeed
        );

        FHE.allowThis(
            plan.complianceEnabled
        );

        FHE.allowSender(
            plan.complianceEnabled
        );

        for (
            uint8 i;
            i < len;
            ++i
        ) {
            plan.targetBps[i] =
                FHE.asEuint64(
                    input
                        .encryptedTargets[i]
                );

            plan.exposure[i] =
                FHE.asEuint64(0);

            _allowOwnerAndContract(
                plan.targetBps[i]
            );

            _allowOwnerAndContract(
                plan.exposure[i]
            );
        }

        emit PlanCreated(
            planId,
            msg.sender,
            input.marketType,
            input.strategyKind,
            input.executionMode,
            input.capabilities
        );
    }

    function setPlanArmed(
        bytes32 planId,
        bool armed
    )
        external
        onlyPlanOwner(planId)
    {
        ExecutionPlan storage plan =
            _plans[planId];

        if (!plan.active) {
            revert PlanInactive();
        }

        plan.armed =
            armed;

        emit PlanArmed(
            planId,
            armed
        );
    }

    function deactivatePlan(
        bytes32 planId
    )
        external
        onlyPlanOwner(planId)
    {
        _plans[planId]
            .active = false;

        _plans[planId]
            .armed = false;

        emit PlanDeactivated(
            planId
        );
    }

    /*//////////////////////////////////////////////////////////////
                       ETOKEN MARKETS
    //////////////////////////////////////////////////////////////*/

    function createETokenMarket(
        bytes32 planId,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        uint8 assetIndex,
        int24 defaultTickLower,
        int24 defaultTickUpper,
        bytes32 positionSalt
    )
        external
        onlyPlanOwner(planId)
        returns (PoolId poolId)
    {
        return _createETokenMarket(
            planId,
            key,
            sqrtPriceX96,
            assetIndex,
            defaultTickLower,
            defaultTickUpper,
            positionSalt,
            AccessMode.PERMISSIONLESS
        );
    }

    function createPermissionedETokenMarket(
        bytes32 planId,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        uint8 assetIndex,
        int24 defaultTickLower,
        int24 defaultTickUpper,
        bytes32 positionSalt
    )
        external
        onlyPlanOwner(planId)
        returns (PoolId poolId)
    {
        return _createETokenMarket(
            planId,
            key,
            sqrtPriceX96,
            assetIndex,
            defaultTickLower,
            defaultTickUpper,
            positionSalt,
            AccessMode.PERMISSIONED
        );
    }

    function _createETokenMarket(
        bytes32 planId,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        uint8 assetIndex,
        int24 defaultTickLower,
        int24 defaultTickUpper,
        bytes32 positionSalt,
        AccessMode accessMode
    )
        internal
        returns (PoolId poolId)
    {
        ExecutionPlan storage plan =
            _plans[planId];

        if (
            plan.marketType
                != MarketType.ETOKEN
        ) {
            revert WrongMarketType();
        }

        if (
            assetIndex
                >= plan.assetCount
        ) {
            revert InvalidAssetIndex();
        }

        if (
            address(key.hooks)
                != address(this)
        ) {
            revert InvalidMarket();
        }

        if (
            defaultTickLower
                >= defaultTickUpper
        ) {
            revert InvalidTicks();
        }

        address currency0 =
            _currencyToToken(
                key.currency0
            );

        address currency1 =
            _currencyToToken(
                key.currency1
            );

        (
            address token0,
            bool adapter0
        ) = _resolveETokenCurrency(
            currency0
        );

        (
            address token1,
            bool adapter1
        ) = _resolveETokenCurrency(
            currency1
        );

        if (
            accessMode
                == AccessMode.PERMISSIONED
        ) {
            if (
                address(
                    permissionsAdapterFactory
                )
                    == address(0)
            ) {
                revert
                    PermissionedFactoryNotConfigured();
            }

            if (
                !adapter0
                    && !adapter1
            ) {
                revert
                    PermissionedAdapterRequired();
            }
        } else {
            if (
                adapter0
                    || adapter1
            ) {
                revert
                    PermissionedAdapterRequired();
            }
        }

        if (
            !approvedEToken[token0]
                || !approvedEToken[token1]
        ) {
            revert UnapprovedToken();
        }

        _requireHybridEToken(
            token0
        );

        _requireHybridEToken(
            token1
        );

        if (
            _supportsInterface(
                token0,
                type(IERC1155)
                    .interfaceId
            )
                || _supportsInterface(
                    token1,
                    type(IERC1155)
                        .interfaceId
                )
        ) {
            revert
                MixedAssetStandards();
        }

        poolId =
            key.toId();

        ETokenMarket storage market =
            eTokenMarkets[poolId];

        if (market.initialized) {
            revert InvalidMarket();
        }

        market.initialized = true;
        market.planId = planId;
        market.assetIndex = assetIndex;
        market.accessMode = accessMode;
        market.token0 = token0;
        market.token1 = token1;
        market.defaultTickLower =
            defaultTickLower;
        market.defaultTickUpper =
            defaultTickUpper;
        market.positionSalt =
            positionSalt;

        poolManager.initialize(
            key,
            sqrtPriceX96
        );

        emit ETokenMarketCreated(
            poolId,
            planId,
            token0,
            token1,
            assetIndex
        );

        emit ETokenAccessModeSet(
            poolId,
            accessMode,
            token0,
            token1
        );
    }

    function executeETokenRebalance(
        bytes32 executionId,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes32 positionSalt
    )
        external
        onlyProtocolModule
        nonReentrant
        returns (bytes memory result)
    {
        if (
            executionId
                == bytes32(0)
        ) {
            revert InvalidExecutionId();
        }

        if (
            processedExecutions[
                executionId
            ]
        ) {
            revert
                ExecutionAlreadyProcessed();
        }

        if (
            liquidityDelta == 0
        ) {
            revert
                InvalidLiquidityDelta();
        }

        if (
            tickLower >= tickUpper
        ) {
            revert InvalidTicks();
        }

        PoolId poolId =
            key.toId();

        ETokenMarket storage market =
            eTokenMarkets[poolId];

        if (!market.initialized) {
            revert InvalidMarket();
        }

        _requireOperational(
            market.paused,
            bytes32(
                PoolId.unwrap(
                    poolId
                )
            )
        );

        ExecutionPlan storage plan =
            _plans[
                market.planId
            ];

        _requireExecutable(
            plan,
            CAP_TEMPORARY_LIQUIDITY
                | CAP_PERSISTENT_LIQUIDITY,
            true
        );

        processedExecutions[
            executionId
        ] = true;

        LiquidityExecution memory request =
            LiquidityExecution({
                action:
                    UnlockAction
                        .MODIFY_LIQUIDITY,
                planId:
                    market.planId,
                executionId:
                    executionId,
                key:
                    key,
                tickLower:
                    tickLower,
                tickUpper:
                    tickUpper,
                liquidityDelta:
                    liquidityDelta,
                positionSalt:
                    positionSalt
            });

        result =
            poolManager.unlock(
                abi.encode(request)
            );
    }

    function unlockCallback(
        bytes calldata data
    )
        external
        override
        returns (bytes memory result)
    {
        if (
            msg.sender
                != address(poolManager)
        ) {
            revert OnlyPoolManager();
        }

        LiquidityExecution memory request =
            abi.decode(
                data,
                (LiquidityExecution)
            );

        if (
            request.action
                != UnlockAction
                    .MODIFY_LIQUIDITY
        ) {
            revert InvalidMarket();
        }

        PoolId poolId =
            request.key.toId();

        ETokenMarket storage market =
            eTokenMarkets[poolId];

        if (
            !market.initialized
                || market.planId
                    != request.planId
        ) {
            revert InvalidMarket();
        }

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({
                tickLower:
                    request.tickLower,
                tickUpper:
                    request.tickUpper,
                liquidityDelta:
                    request.liquidityDelta,
                salt:
                    request.positionSalt
            });

        (
            BalanceDelta callerDelta,
            BalanceDelta feesAccrued
        ) =
            poolManager
                .modifyLiquidity(
                    request.key,
                    params,
                    bytes(
                        "SCHRODINGER_REBALANCE"
                    )
                );

        _settleOrTake(
            request
                .key
                .currency0,
            callerDelta.amount0()
        );

        _settleOrTake(
            request
                .key
                .currency1,
            callerDelta.amount1()
        );

        emit ETokenRebalanceExecuted(
            poolId,
            request.planId,
            request.executionId,
            request.liquidityDelta,
            callerDelta.amount0(),
            callerDelta.amount1()
        );

        return abi.encode(
            callerDelta,
            feesAccrued
        );
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    )
        internal
        returns (
            bytes4,
            BeforeSwapDelta,
            uint24
        )
    {
        PoolId poolId =
            key.toId();

        ETokenMarket storage market =
            eTokenMarkets[poolId];

        if (!market.initialized) {
            return (
                IHooks
                    .beforeSwap
                    .selector,
                BeforeSwapDeltaLibrary
                    .ZERO_DELTA,
                0
            );
        }

        _requireOperational(
            market.paused,
            bytes32(
                PoolId.unwrap(
                    poolId
                )
            )
        );

        _requirePermissionedSwapWrapper(
            sender,
            key
        );

        ExecutionPlan storage plan =
            _plans[
                market.planId
            ];

        if (
            !plan.active
                || !plan.armed
        ) {
            return (
                IHooks
                    .beforeSwap
                    .selector,
                BeforeSwapDeltaLibrary
                    .ZERO_DELTA,
                0
            );
        }

        _requireCapability(
            plan,
            CAP_BEFORE_SWAP
        );

        _evaluatePrivateRebalance(
            plan,
            market.assetIndex
        );

        emit PrivateRebalanceEvaluated(
            market.planId,
            bytes32(
                PoolId.unwrap(
                    poolId
                )
            ),
            MarketType.ETOKEN
        );

        return (
            IHooks
                .beforeSwap
                .selector,
            BeforeSwapDeltaLibrary
                .ZERO_DELTA,
            0
        );
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    )
        internal
        returns (
            bytes4,
            int128
        )
    {
        PoolId poolId =
            key.toId();

        ETokenMarket storage market =
            eTokenMarkets[poolId];

        if (!market.initialized) {
            return (
                IHooks
                    .afterSwap
                    .selector,
                0
            );
        }

        ExecutionPlan storage plan =
            _plans[
                market.planId
            ];

        if (!plan.active) {
            return (
                IHooks
                    .afterSwap
                    .selector,
                0
            );
        }

        _requireCapability(
            plan,
            CAP_AFTER_SWAP
        );

        uint8 asset =
            market.assetIndex;

        euint64 encryptedDelta =
            _publicDeltaToEncryptedAbs(
                delta.amount0()
            );

        plan.exposure[asset] =
            FHE.add(
                plan.exposure[asset],
                encryptedDelta
            );

        plan.drift[asset] =
            _encryptedAbsDiff(
                plan.exposure[asset],
                plan.targetBps[asset]
            );

        plan.lastRebalanceDelta[asset] =
            _sizedEncryptedRebalanceDelta(
                plan,
                plan.drift[asset]
            );

        _allowOwnerAndContract(
            plan.exposure[asset]
        );

        _allowOwnerAndContract(
            plan.drift[asset]
        );

        _allowOwnerAndContract(
            plan
                .lastRebalanceDelta[
                    asset
                ]
        );

        if (
            market.accessMode
                == AccessMode.PERMISSIONED
        ) {
            emit PermissionedSwapObserved(
                poolId,
                sender,
                market.token0,
                market.token1
            );
        }

        return (
            IHooks
                .afterSwap
                .selector,
            0
        );
    }

    /*//////////////////////////////////////////////////////////////
                         EASSET MARKETS
    //////////////////////////////////////////////////////////////*/

    function createEAssetMarket(
        bytes32 planId,
        uint8 assetIndex,
        address positionToken,
        uint256 positionTokenId,
        address backingBond,
        uint256 bondClassId,
        uint256 bondNonceId,
        address settlementEToken
    )
        external
        onlyPlanOwner(planId)
        returns (bytes32 marketId)
    {
        return _createEAssetMarket(
            planId,
            assetIndex,
            positionToken,
            positionTokenId,
            backingBond,
            bondClassId,
            bondNonceId,
            settlementEToken,
            AccessMode.PERMISSIONLESS,
            IAllowlistChecker(
                address(0)
            )
        );
    }

    function createPermissionedEAssetMarket(
        bytes32 planId,
        uint8 assetIndex,
        address positionToken,
        uint256 positionTokenId,
        address backingBond,
        uint256 bondClassId,
        uint256 bondNonceId,
        address settlementEToken,
        IAllowlistChecker allowlistChecker
    )
        external
        onlyPlanOwner(planId)
        returns (bytes32 marketId)
    {
        _requireAllowlistChecker(
            address(
                allowlistChecker
            )
        );

        return _createEAssetMarket(
            planId,
            assetIndex,
            positionToken,
            positionTokenId,
            backingBond,
            bondClassId,
            bondNonceId,
            settlementEToken,
            AccessMode.PERMISSIONED,
            allowlistChecker
        );
    }

    function _createEAssetMarket(
        bytes32 planId,
        uint8 assetIndex,
        address positionToken,
        uint256 positionTokenId,
        address backingBond,
        uint256 bondClassId,
        uint256 bondNonceId,
        address settlementEToken,
        AccessMode accessMode,
        IAllowlistChecker allowlistChecker
    )
        internal
        returns (bytes32 marketId)
    {
        ExecutionPlan storage plan =
            _plans[planId];

        if (
            plan.marketType
                != MarketType.EASSET
        ) {
            revert WrongMarketType();
        }

        if (
            assetIndex
                >= plan.assetCount
        ) {
            revert InvalidAssetIndex();
        }

        if (
            !approvedEAssetToken[
                positionToken
            ]
                || !approvedBondContract[
                    backingBond
                ]
                || !approvedEToken[
                    settlementEToken
                ]
        ) {
            revert UnapprovedToken();
        }

        _requireEncrypted1155(
            positionToken
        );

        _requireERC3475(
            backingBond
        );

        _requireHybridEToken(
            settlementEToken
        );

        if (
            _supportsInterface(
                positionToken,
                ERC7984_INTERFACE_ID
            )
                || _supportsInterface(
                    settlementEToken,
                    type(IERC1155)
                        .interfaceId
                )
        ) {
            revert
                MixedAssetStandards();
        }

        marketId =
            keccak256(
                abi.encode(
                    MarketType.EASSET,
                    positionToken,
                    positionTokenId,
                    backingBond,
                    bondClassId,
                    bondNonceId,
                    address(this)
                )
            );

        EAssetMarket storage market =
            _eAssetMarkets[
                marketId
            ];

        if (market.initialized) {
            revert InvalidMarket();
        }

        market.initialized = true;
        market.planId =
            planId;
        market.assetIndex =
            assetIndex;
        market.accessMode =
            accessMode;
        market.allowlistChecker =
            allowlistChecker;
        market.positionToken =
            positionToken;
        market.positionTokenId =
            positionTokenId;
        market.backingBond =
            backingBond;
        market.bondClassId =
            bondClassId;
        market.bondNonceId =
            bondNonceId;
        market.settlementEToken =
            settlementEToken;

        market.encryptedInventory =
            FHE.asEuint64(0);

        market.encryptedCollateral =
            FHE.asEuint64(0);

        market.encryptedLastDelta =
            FHE.asEuint64(0);

        _allowOwnerAndContract(
            market.encryptedInventory
        );

        _allowOwnerAndContract(
            market.encryptedCollateral
        );

        _allowOwnerAndContract(
            market.encryptedLastDelta
        );

        bytes32 positionRef =
            keccak256(
                abi.encode(
                    positionToken,
                    positionTokenId
                )
            );

        if (
            eAssetMarketByPosition[
                positionRef
            ]
                != bytes32(0)
        ) {
            revert InvalidMarket();
        }

        eAssetMarketByPosition[
            positionRef
        ] = marketId;

        emit EAssetMarketCreated(
            marketId,
            planId,
            positionToken,
            positionTokenId,
            backingBond,
            settlementEToken
        );

        emit EAssetAccessModeSet(
            marketId,
            accessMode,
            address(
                allowlistChecker
            )
        );
    }

    function executeEAssetRebalance(
        bytes32 marketId,
        bytes32 executionId,
        InEuint64 calldata encryptedInventoryDelta,
        InEuint64 calldata encryptedCollateralDelta
    )
        external
        onlyProtocolModule
        nonReentrant
    {
        if (
            executionId
                == bytes32(0)
        ) {
            revert InvalidExecutionId();
        }

        if (
            processedExecutions[
                executionId
            ]
        ) {
            revert
                ExecutionAlreadyProcessed();
        }

        EAssetMarket storage market =
            _eAssetMarkets[
                marketId
            ];

        if (!market.initialized) {
            revert InvalidMarket();
        }

        _requireOperational(
            market.paused,
            marketId
        );

        ExecutionPlan storage plan =
            _plans[
                market.planId
            ];

        _requireExecutable(
            plan,
            CAP_EASSET_REBALANCE,
            false
        );

        euint64 inventoryDelta =
            FHE.asEuint64(
                encryptedInventoryDelta
            );

        euint64 collateralDelta =
            FHE.asEuint64(
                encryptedCollateralDelta
            );

        market.encryptedInventory =
            FHE.add(
                market.encryptedInventory,
                inventoryDelta
            );

        market.encryptedCollateral =
            FHE.add(
                market.encryptedCollateral,
                collateralDelta
            );

        market.encryptedLastDelta =
            inventoryDelta;

        plan.exposure[
            market.assetIndex
        ] =
            FHE.add(
                plan.exposure[
                    market.assetIndex
                ],
                inventoryDelta
            );

        plan.drift[
            market.assetIndex
        ] =
            _encryptedAbsDiff(
                plan.exposure[
                    market.assetIndex
                ],
                plan.targetBps[
                    market.assetIndex
                ]
            );

        plan.lastRebalanceDelta[
            market.assetIndex
        ] =
            _sizedEncryptedRebalanceDelta(
                plan,
                plan.drift[
                    market.assetIndex
                ]
            );

        _allowOwnerAndContract(
            market.encryptedInventory
        );

        _allowOwnerAndContract(
            market.encryptedCollateral
        );

        _allowOwnerAndContract(
            market.encryptedLastDelta
        );

        _allowOwnerAndContract(
            plan.exposure[
                market.assetIndex
            ]
        );

        _allowOwnerAndContract(
            plan.drift[
                market.assetIndex
            ]
        );

        _allowOwnerAndContract(
            plan.lastRebalanceDelta[
                market.assetIndex
            ]
        );

        FHE.allow(
            market.encryptedInventory,
            plan.owner
        );

        FHE.allow(
            market.encryptedCollateral,
            plan.owner
        );

        FHE.allow(
            market.encryptedLastDelta,
            plan.owner
        );

        FHE.allow(
            plan.exposure[
                market.assetIndex
            ],
            plan.owner
        );

        FHE.allow(
            plan.drift[
                market.assetIndex
            ],
            plan.owner
        );

        FHE.allow(
            plan.lastRebalanceDelta[
                market.assetIndex
            ],
            plan.owner
        );

        processedExecutions[
            executionId
        ] = true;

        emit EAssetRebalanceRecorded(
            marketId,
            market.planId,
            executionId
        );
    }

    /*//////////////////////////////////////////////////////////////
                          TELLOR V1
    //////////////////////////////////////////////////////////////*/

    function receiveTellorSignal(
        bytes32 marketRef,
        bytes32 planId,
        bytes32 queryId,
        uint256 value,
        uint256 timestamp,
        bytes calldata
    )
        external
        onlyProtocolModule
    {
        ExecutionPlan storage plan =
            _plans[planId];

        if (
            plan.owner
                == address(0)
        ) {
            revert InvalidPlan();
        }

        _requireCapability(
            plan,
            CAP_ORACLE_REFRESH
        );

        plan.lastSignalAt =
            uint64(
                block.timestamp
            );

        emit OracleSignalReceived(
            marketRef,
            planId,
            queryId,
            value,
            timestamp
        );
    }

    function setOracleDegraded(
        bytes32 marketRef,
        bool degraded
    )
        external
        onlyProtocolModule
    {
        oracleDegraded[
            marketRef
        ] = degraded;
    }

    /*//////////////////////////////////////////////////////////////
                           CORE VIEWS
    //////////////////////////////////////////////////////////////*/

    function getPlanMetadata(
        bytes32 planId
    )
        external
        view
        returns (
            address planOwner,
            MarketType marketType,
            StrategyKind strategyKind,
            ExecutionMode executionMode,
            uint256 capabilities,
            bool active,
            bool armed,
            uint8 assetCount,
            uint64 lastSignalAt
        )
    {
        ExecutionPlan storage plan =
            _plans[planId];

        if (
            plan.owner
                == address(0)
        ) {
            revert InvalidPlan();
        }

        return (
            plan.owner,
            plan.marketType,
            plan.strategyKind,
            plan.executionMode,
            plan.capabilities,
            plan.active,
            plan.armed,
            plan.assetCount,
            plan.lastSignalAt
        );
    }

    function getEAssetMarket(
        bytes32 marketId
    )
        external
        view
        returns (
            bool initialized,
            bool paused,
            bytes32 planId,
            uint8 assetIndex,
            address positionToken,
            uint256 positionTokenId,
            address backingBond,
            uint256 bondClassId,
            uint256 bondNonceId,
            address settlementEToken
        )
    {
        EAssetMarket storage market =
            _eAssetMarkets[
                marketId
            ];

        return (
            market.initialized,
            market.paused,
            market.planId,
            market.assetIndex,
            market.positionToken,
            market.positionTokenId,
            market.backingBond,
            market.bondClassId,
            market.bondNonceId,
            market.settlementEToken
        );
    }

    /*//////////////////////////////////////////////////////////////
                     PERMISSIONED POOL INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _beforeInitializePermissionCheck(
        address,
        PoolKey calldata key
    )
        internal
        view
    {
        PoolId poolId =
            key.toId();

        ETokenMarket storage market =
            eTokenMarkets[
                poolId
            ];

        if (
            !market.initialized
                || market.accessMode
                    == AccessMode
                        .PERMISSIONLESS
        ) {
            return;
        }

        if (
            address(
                permissionsAdapterFactory
            )
                == address(0)
        ) {
            revert
                PermissionedFactoryNotConfigured();
        }

        address currency0 =
            _currencyToToken(
                key.currency0
            );

        address currency1 =
            _currencyToToken(
                key.currency1
            );

        (
            ,
            bool adapter0
        ) =
            _resolveETokenCurrency(
                currency0
            );

        (
            ,
            bool adapter1
        ) =
            _resolveETokenCurrency(
                currency1
            );

        if (
            !adapter0
                && !adapter1
        ) {
            revert
                PermissionedAdapterRequired();
        }
    }

    function _requirePermissionedSwapWrapper(
        address wrapper,
        PoolKey calldata key
    )
        internal
        view
    {
        ETokenMarket storage market =
            eTokenMarkets[
                key.toId()
            ];

        if (
            !market.initialized
                || market.accessMode
                    == AccessMode
                        .PERMISSIONLESS
        ) {
            return;
        }

        _requireAdapterWrapperForAction(
            _currencyToToken(
                key.currency0
            ),
            wrapper,
            true
        );

        _requireAdapterWrapperForAction(
            _currencyToToken(
                key.currency1
            ),
            wrapper,
            true
        );
    }

    function _requirePermissionedLiquidityWrapper(
        address wrapper,
        PoolKey calldata key
    )
        internal
        view
    {
        ETokenMarket storage market =
            eTokenMarkets[
                key.toId()
            ];

        if (
            !market.initialized
                || market.accessMode
                    == AccessMode
                        .PERMISSIONLESS
        ) {
            return;
        }

        _requireAdapterWrapperForAction(
            _currencyToToken(
                key.currency0
            ),
            wrapper,
            false
        );

        _requireAdapterWrapperForAction(
            _currencyToToken(
                key.currency1
            ),
            wrapper,
            false
        );
    }

    function _requireAdapterWrapperForAction(
        address currency,
        address wrapper,
        bool requireSwappingEnabled
    )
        internal
        view
    {
        if (
            address(
                permissionsAdapterFactory
            )
                == address(0)
        ) {
            revert
                PermissionedFactoryNotConfigured();
        }

        address underlying =
            permissionsAdapterFactory
                .verifiedPermissionsAdapterOf(
                    currency
                );

        if (
            underlying
                == address(0)
        ) {
            return;
        }

        IPermissionsAdapter adapter =
            IPermissionsAdapter(
                currency
            );

        if (
            adapter.POOL_MANAGER()
                != address(
                    poolManager
                )
        ) {
            revert
                UnverifiedPermissionsAdapter(
                    currency
                );
        }

        if (
            !adapter
                .allowedWrappers(
                    wrapper
                )
        ) {
            revert
                PermissionedWrapperNotAllowed(
                    currency,
                    wrapper
                );
        }

        if (
            requireSwappingEnabled
                && !adapter
                    .swappingEnabled()
        ) {
            revert
                PermissionedSwappingDisabled(
                    currency
                );
        }
    }

    function _resolveETokenCurrency(
        address currency
    )
        internal
        view
        returns (
            address underlying,
            bool isVerifiedAdapter
        )
    {
        if (
            address(
                permissionsAdapterFactory
            )
                != address(0)
        ) {
            underlying =
                permissionsAdapterFactory
                    .verifiedPermissionsAdapterOf(
                        currency
                    );

            if (
                underlying
                    != address(0)
            ) {
                if (
                    IPermissionsAdapter(
                        currency
                    )
                        .POOL_MANAGER()
                        != address(
                            poolManager
                        )
                ) {
                    revert
                        UnverifiedPermissionsAdapter(
                            currency
                        );
                }

                return (
                    underlying,
                    true
                );
            }
        }

        return (
            currency,
            false
        );
    }

    function _requireAllowlistChecker(
        address checker
    )
        internal
        view
    {
        if (
            checker == address(0)
                || !_supportsInterface(
                    checker,
                    type(
                        IAllowlistChecker
                    ).interfaceId
                )
        ) {
            revert
                InvalidAllowlistChecker(
                    checker
                );
        }
    }

    function _requireEAssetPermission(
        bytes32 marketId,
        address account,
        PermissionFlag permission
    )
        internal
        view
    {
        EAssetMarket storage market =
            _eAssetMarkets[
                marketId
            ];

        if (!market.initialized) {
            revert InvalidMarket();
        }

        if (
            market.accessMode
                == AccessMode
                    .PERMISSIONLESS
        ) {
            return;
        }

        PermissionFlag granted =
            market
                .allowlistChecker
                .checkAllowlist(
                    account,
                    market.positionToken
                );

        if (
            (
                PermissionFlag.unwrap(
                    granted
                )
                    & PermissionFlag.unwrap(
                        permission
                    )
            )
                != PermissionFlag.unwrap(
                    permission
                )
        ) {
            revert PermissionDenied(
                account,
                market.positionToken,
                PermissionFlag.unwrap(
                    permission
                )
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                       PRIVATE REBALANCING
    //////////////////////////////////////////////////////////////*/

    function _evaluatePrivateRebalance(
        ExecutionPlan storage plan,
        uint8 asset
    )
        internal
    {
        euint64 drift =
            _encryptedAbsDiff(
                plan.exposure[asset],
                plan.targetBps[asset]
            );

        euint64 threshold =
            _volatilityAdjustedThreshold(
                plan
            );

        euint64 proposedDelta =
            _sizedEncryptedRebalanceDelta(
                plan,
                drift
            );

        ebool thresholdPassed =
            FHE.gt(
                drift,
                threshold
            );

        ebool allocationAllowed =
            FHE.lte(
                proposedDelta,
                plan.maximumAllocation
            );

        plan.drift[asset] =
            drift;

        plan.lastRebalanceDelta[
            asset
        ] =
            proposedDelta;

        plan.lastExecutionApproved =
            FHE.and(
                thresholdPassed,
                allocationAllowed
            );

        _allowOwnerAndContract(
            plan.drift[asset]
        );

        _allowOwnerAndContract(
            plan.lastRebalanceDelta[
                asset
            ]
        );

        FHE.allowThis(
            plan.lastExecutionApproved
        );

        FHE.allow(
            plan.lastExecutionApproved,
            plan.owner
        );
    }

    function _requireExecutable(
        ExecutionPlan storage plan,
        uint256 anyCapabilityMask,
        bool requireEToken
    )
        internal
        view
    {
        if (!plan.active) {
            revert PlanInactive();
        }

        if (!plan.armed) {
            revert PlanNotArmed();
        }

        if (
            requireEToken
                && plan.marketType
                    != MarketType.ETOKEN
        ) {
            revert WrongMarketType();
        }

        if (
            !requireEToken
                && plan.marketType
                    != MarketType.EASSET
        ) {
            revert WrongMarketType();
        }

        if (
            (
                plan.capabilities
                    & anyCapabilityMask
            )
                == 0
        ) {
            revert CapabilityDisabled();
        }
    }

    function _requireOperational(
        bool marketPaused,
        bytes32 marketRef
    )
        internal
        view
    {
        if (globalPaused) {
            revert GlobalPause();
        }

        if (
            marketPaused
                || oracleDegraded[
                    marketRef
                ]
        ) {
            revert MarketPaused();
        }
    }

    function _requireCapability(
        ExecutionPlan storage plan,
        uint256 capability
    )
        internal
        view
    {
        if (
            (
                plan.capabilities
                    & capability
            )
                != capability
        ) {
            revert CapabilityDisabled();
        }
    }

    /*//////////////////////////////////////////////////////////////
                       UNISWAP ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function _settleOrTake(
        Currency currency,
        int128 delta
    )
        internal
    {
        if (delta < 0) {
            uint256 amount =
                uint256(
                    uint128(
                        -delta
                    )
                );

            poolManager.sync(
                currency
            );

            IERC20(
                Currency.unwrap(
                    currency
                )
            )
                .safeTransfer(
                    address(
                        poolManager
                    ),
                    amount
                );

            poolManager.settle();
        } else if (
            delta > 0
        ) {
            poolManager.take(
                currency,
                address(this),
                uint256(
                    uint128(
                        delta
                    )
                )
            );
        }
    }

    function _currencyToToken(
        Currency currency
    )
        internal
        pure
        returns (address token)
    {
        token =
            Currency.unwrap(
                currency
            );

        if (
            token
                == address(0)
        ) {
            revert
                NativeTokenNotAllowed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                       ASSET VALIDATION
    //////////////////////////////////////////////////////////////*/

    function _requireHybridEToken(
        address token
    )
        internal
        view
    {
        if (
            token.code.length == 0
        ) {
            revert NonHybridEToken();
        }

        if (
            !_supportsInterface(
                token,
                ERC7984_INTERFACE_ID
            )
        ) {
            revert NonHybridEToken();
        }

        (
            bool supplyOk,
            bytes memory supplyData
        ) =
            token.staticcall(
                abi.encodeCall(
                    IERC20.totalSupply,
                    ()
                )
            );

        (
            bool balanceOk,
            bytes memory balanceData
        ) =
            token.staticcall(
                abi.encodeCall(
                    IERC20.balanceOf,
                    (
                        address(this)
                    )
                )
            );

        if (
            !supplyOk
                || supplyData.length
                    < 32
                || !balanceOk
                || balanceData.length
                    < 32
        ) {
            revert NonHybridEToken();
        }
    }

    function _requireEncrypted1155(
        address token
    )
        internal
        view
    {
        if (
            token.code.length == 0
                || !_supportsInterface(
                    token,
                    type(IERC1155)
                        .interfaceId
                )
                || !_supportsInterface(
                    token,
                    ENCRYPTED_1155_INTERFACE_ID
                )
        ) {
            revert
                NonEncryptedERC1155();
        }
    }

    function _requireERC3475(
        address bond
    )
        internal
        view
    {
        if (
            bond.code.length == 0
                || !_supportsInterface(
                    bond,
                    ERC3475_BACKING_INTERFACE_ID
                )
        ) {
            revert
                NonERC3475Backing();
        }
    }

    function _supportsInterface(
        address target,
        bytes4 interfaceId
    )
        internal
        view
        returns (bool)
    {
        try
            IERC165(target)
                .supportsInterface(
                    interfaceId
                )
        returns (
            bool supported
        ) {
            return supported;
        } catch {
            return false;
        }
    }

    /*//////////////////////////////////////////////////////////////
                           FHE HELPERS
    //////////////////////////////////////////////////////////////*/

    function _publicDeltaToEncryptedAbs(
        int128 amount
    )
        internal
        returns (euint64)
    {
        uint128 absolute =
            amount >= 0
                ? uint128(amount)
                : uint128(-amount);

        return
            FHE.asEuint64(
                uint64(
                    absolute
                )
            );
    }

    function _encryptedAbsDiff(
        euint64 a,
        euint64 b
    )
        internal
        returns (euint64)
    {
        ebool aGreater =
            FHE.gt(
                a,
                b
            );

        return FHE.select(
            aGreater,
            FHE.sub(
                a,
                b
            ),
            FHE.sub(
                b,
                a
            )
        );
    }

    function _volatilityAdjustedThreshold(
        ExecutionPlan storage plan
    )
        internal
        returns (euint64)
    {
        euint64 volatilityBuffer =
            FHE.div(
                plan.volatilityBps,
                FHE.asEuint64(4)
            );

        euint64 feeCredit =
            FHE.div(
                plan.feeAprBps,
                FHE.asEuint64(8)
            );

        euint64 rawThreshold =
            FHE.add(
                plan
                    .rebalanceThresholdBps,
                volatilityBuffer
            );

        ebool aboveCredit =
            FHE.gt(
                rawThreshold,
                feeCredit
            );

        return FHE.select(
            aboveCredit,
            FHE.sub(
                rawThreshold,
                feeCredit
            ),
            FHE.asEuint64(1)
        );
    }

    function _sizedEncryptedRebalanceDelta(
        ExecutionPlan storage plan,
        euint64 drift
    )
        internal
        returns (euint64)
    {
        euint64 weighted =
            FHE.mul(
                drift,
                plan.hedgeIntensityBps
            );

        return
            FHE.div(
                weighted,
                FHE.asEuint64(
                    BPS
                )
            );
    }

    function _allowOwnerAndContract(
        euint64 value
    )
        internal
    {
        FHE.allowThis(
            value
        );

        FHE.allowSender(
            value
        );
    }

    /*//////////////////////////////////////////////////////////////
                       ERC1155 RECEIVER
    //////////////////////////////////////////////////////////////*/

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    )
        external
        pure
        returns (bytes4)
    {
        return
            IERC1155Receiver
                .onERC1155Received
                .selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    )
        external
        pure
        returns (bytes4)
    {
        return
            IERC1155Receiver
                .onERC1155BatchReceived
                .selector;
    }

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        pure
        override
        returns (bool)
    {
        return
            interfaceId
                == type(
                    IERC1155Receiver
                ).interfaceId
                || interfaceId
                    == type(
                        IERC165
                    ).interfaceId;
    }
}
