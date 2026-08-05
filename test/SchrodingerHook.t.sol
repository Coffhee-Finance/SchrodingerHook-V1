// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SchrodingerHook} from "../src/SchrodingerHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @notice Minimal ERC20 surface plus ERC165-advertised ERC7984 support.
 * @dev The hook's whitelist validation checks ERC7984 via supportsInterface and
 *      ERC20 compatibility via totalSupply()/balanceOf() static calls.
 */
contract MockHybridEToken is IERC20, IERC165 {
    string public constant name = "Mock eToken";
    string public constant symbol = "meTKN";
    uint8 public constant decimals = 18;

    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    bytes4 internal constant ERC7984_ID = 0x4958f2a4;

    function supportsInterface(bytes4 interfaceId) external pure virtual override returns (bool) {
        return interfaceId == ERC7984_ID || interfaceId == type(IERC165).interfaceId;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= amount, "ALLOWANCE");
        if (currentAllowance != type(uint256).max) {
            allowance[from][msg.sender] = currentAllowance - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "ZERO_TO");
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract MockERC20Only is MockHybridEToken {
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

/**
 * @notice Interface-advertising mock for encrypted ERC1155 whitelist tests.
 * @dev Transfer functions are not needed for the approval tests below.
 */
contract MockEncrypted1155 is IERC165 {
    bytes4 public immutable encryptedInterfaceId;

    constructor(bytes4 id) {
        encryptedInterfaceId = id;
    }

    function supportsInterface(bytes4 interfaceId) external view override returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IERC1155).interfaceId
            || interfaceId == encryptedInterfaceId;
    }
}

contract MockERC1155Only is IERC165 {
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IERC1155).interfaceId;
    }
}

contract MockERC3475Backing is IERC165 {
    bytes4 public immutable backingInterfaceId;

    constructor(bytes4 id) {
        backingInterfaceId = id;
    }

    function supportsInterface(bytes4 interfaceId) external view override returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == backingInterfaceId;
    }
}

contract MockNonBond is IERC165 {
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

library TestHookMiner {
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    error HookSaltNotFound();

    function find(
        address create2Deployer,
        uint160 requiredFlags,
        bytes memory creationCode,
        bytes memory constructorArgs,
        uint256 maxIterations
    ) internal pure returns (address predicted, bytes32 salt) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        for (uint256 i; i < maxIterations; ++i) {
            salt = bytes32(i);
            predicted = compute(create2Deployer, salt, initCodeHash);
            if ((uint160(predicted) & ALL_HOOK_MASK) == requiredFlags) {
                return (predicted, salt);
            }
        }

        revert HookSaltNotFound();
    }

    function compute(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)
                    )
                )
            )
        );
    }
}

contract SchrodingerHookTest is Test {
    uint160 internal constant REQUIRED_FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    SchrodingerHook internal hook;

    address internal owner;
    address internal user;
    address internal protocolModule;
    address internal poolManagerAddress;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");
        protocolModule = makeAddr("protocolModule");
        poolManagerAddress = makeAddr("poolManager");
        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManagerAddress),
            owner
        );

        (address predicted, bytes32 salt) = TestHookMiner.find(
            address(this),
            REQUIRED_FLAGS,
            type(SchrodingerHook).creationCode,
            constructorArgs,
            500_000
        );

        hook = new SchrodingerHook{salt: salt}(
            IPoolManager(poolManagerAddress),
            owner
        );

        assertEq(address(hook), predicted, "wrong CREATE2 hook address");
    }

    /*//////////////////////////////////////////////////////////////
                              DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function test_ConstructorSetsOwnerAndPoolManager() public view {
        assertEq(hook.owner(), owner);
        assertEq(address(hook.poolManager()), poolManagerAddress);
        assertTrue(hook.approvedProtocolModule(owner));
    }

    function test_HookAddressHasOnlyRequiredFlags() public view {
        assertEq(uint160(address(hook)) & ALL_HOOK_MASK, REQUIRED_FLAGS);
    }

    function test_GetHookPermissionsMatchesAddressFlags() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeInitialize);
        assertFalse(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertFalse(permissions.afterSwapReturnDelta);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);
    }

    function test_RevertDeploymentWithZeroManager() public {
        bytes memory constructorArgs = abi.encode(IPoolManager(address(0)), owner);
        (, bytes32 salt) = TestHookMiner.find(
            address(this),
            REQUIRED_FLAGS,
            type(SchrodingerHook).creationCode,
            constructorArgs,
            500_000
        );

        vm.expectRevert(SchrodingerHook.InvalidAddress.selector);
        new SchrodingerHook{salt: salt}(IPoolManager(address(0)), owner);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_OwnerCanSetProtocolModule() public {
        vm.prank(owner);
        hook.setProtocolModule(protocolModule, true);
        assertTrue(hook.approvedProtocolModule(protocolModule));

        vm.prank(owner);
        hook.setProtocolModule(protocolModule, false);
        assertFalse(hook.approvedProtocolModule(protocolModule));
    }

    function test_NonOwnerCannotSetProtocolModule() public {
        vm.prank(user);
        vm.expectRevert();
        hook.setProtocolModule(protocolModule, true);
    }

    function test_RevertSettingZeroProtocolModule() public {
        vm.prank(owner);
        vm.expectRevert(SchrodingerHook.InvalidAddress.selector);
        hook.setProtocolModule(address(0), true);
    }

    function test_OwnerCanPauseAndUnpauseGlobally() public {
        vm.prank(owner);
        hook.setGlobalPaused(true);
        assertTrue(hook.globalPaused());

        vm.prank(owner);
        hook.setGlobalPaused(false);
        assertFalse(hook.globalPaused());
    }

    /*//////////////////////////////////////////////////////////////
                      TOKEN-STANDARD REQUIREMENTS
    //////////////////////////////////////////////////////////////*/

    function test_OwnerCanApproveHybridERC20ERC7984EToken() public {
        MockHybridEToken token = new MockHybridEToken();

        vm.prank(owner);
        hook.setApprovedEToken(address(token), true);

        assertTrue(hook.approvedEToken(address(token)));
    }

    function test_RevertApprovingERC20WithoutERC7984() public {
        MockERC20Only token = new MockERC20Only();

        vm.prank(owner);
        vm.expectRevert(SchrodingerHook.NonHybridEToken.selector);
        hook.setApprovedEToken(address(token), true);
    }

    function test_RevertApprovingEOAAsEToken() public {
        vm.prank(owner);
        vm.expectRevert(SchrodingerHook.NonHybridEToken.selector);
        hook.setApprovedEToken(makeAddr("notToken"), true);
    }

    function test_OwnerCanApproveEncryptedERC1155EAsset() public {
        MockEncrypted1155 token = new MockEncrypted1155(
            hook.ENCRYPTED_1155_INTERFACE_ID()
        );

        vm.prank(owner);
        hook.setApprovedEAssetToken(address(token), true);

        assertTrue(hook.approvedEAssetToken(address(token)));
    }

    function test_RevertApprovingPlainERC1155AsEAsset() public {
        MockERC1155Only token = new MockERC1155Only();

        vm.prank(owner);
        vm.expectRevert(SchrodingerHook.NonEncryptedERC1155.selector);
        hook.setApprovedEAssetToken(address(token), true);
    }

    function test_OwnerCanApproveERC3475Backing() public {
        MockERC3475Backing bond = new MockERC3475Backing(
            hook.ERC3475_BACKING_INTERFACE_ID()
        );

        vm.prank(owner);
        hook.setApprovedBondContract(address(bond), true);

        assertTrue(hook.approvedBondContract(address(bond)));
    }

    function test_RevertApprovingNonERC3475Contract() public {
        MockNonBond bond = new MockNonBond();

        vm.prank(owner);
        vm.expectRevert(SchrodingerHook.NonERC3475Backing.selector);
        hook.setApprovedBondContract(address(bond), true);
    }

    /*//////////////////////////////////////////////////////////////
                         INVENTORY / CUSTODY
    //////////////////////////////////////////////////////////////*/

    function test_DepositApprovedEToken() public {
        MockHybridEToken token = new MockHybridEToken();
        token.mint(user, 100 ether);

        vm.prank(owner);
        hook.setApprovedEToken(address(token), true);

        vm.startPrank(user);
        token.approve(address(hook), 25 ether);
        hook.depositEToken(address(token), 25 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(address(hook)), 25 ether);
    }

    function test_RevertDepositUnapprovedEToken() public {
        MockHybridEToken token = new MockHybridEToken();
        token.mint(user, 1 ether);

        vm.startPrank(user);
        token.approve(address(hook), 1 ether);
        vm.expectRevert(SchrodingerHook.UnapprovedToken.selector);
        hook.depositEToken(address(token), 1 ether);
        vm.stopPrank();
    }

    function test_OwnerCanWithdrawETokenInventory() public {
        MockHybridEToken token = new MockHybridEToken();
        token.mint(address(hook), 10 ether);

        vm.prank(owner);
        hook.withdrawEToken(address(token), owner, 4 ether);

        assertEq(token.balanceOf(owner), 4 ether);
        assertEq(token.balanceOf(address(hook)), 6 ether);
    }

    /*//////////////////////////////////////////////////////////////
                       CALLBACK / ADAPTER BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    function test_RevertBeforeSwapFromNonPoolManager() public {
        PoolKey memory key = _poolKey();
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 1
        });

        vm.prank(user);
        vm.expectRevert();
        hook.beforeSwap(user, key, params, bytes(""));
    }

    function test_RevertAfterSwapFromNonPoolManager() public {
        PoolKey memory key = _poolKey();
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 1
        });

        vm.prank(user);
        vm.expectRevert();
        hook.afterSwap(user, key, params, BalanceDelta.wrap(0), bytes(""));
    }

    function test_RevertUnlockCallbackFromNonPoolManager() public {
        vm.prank(user);
        vm.expectRevert(SchrodingerHook.OnlyPoolManager.selector);
        hook.unlockCallback(bytes(""));
    }

    function test_RevertAutomationFromUnapprovedCaller() public {
        vm.prank(user);
        vm.expectRevert(SchrodingerHook.OnlyProtocolModule.selector);
        hook.handleSchrodingerAutomation(
            uint8(SchrodingerHook.AutomationAction.ARM_PLAN),
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            bytes("")
        );
    }

    function test_RevertAutomationForUnknownPlan() public {
        vm.prank(owner);
        vm.expectRevert(SchrodingerHook.InvalidPlan.selector);
        hook.handleSchrodingerAutomation(
            uint8(SchrodingerHook.AutomationAction.ARM_PLAN),
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            bytes("")
        );
    }

    function test_RevertTellorSignalFromUnapprovedAdapter() public {
        vm.prank(user);
        vm.expectRevert(SchrodingerHook.OnlyProtocolModule.selector);
        hook.receiveTellorSignal(
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            2_500 ether,
            block.timestamp,
            bytes("proof")
        );
    }

    function test_SupportsERC1155ReceiverInterface() public view {
        assertTrue(hook.supportsInterface(type(IERC1155Receiver).interfaceId));
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId));
    }

    function test_CapabilityBitsAreIndependent() public view {
        uint256[] memory flags = new uint256[](9);
        flags[0] = hook.CAP_BEFORE_SWAP();
        flags[1] = hook.CAP_AFTER_SWAP();
        flags[2] = hook.CAP_TEMPORARY_LIQUIDITY();
        flags[3] = hook.CAP_PERSISTENT_LIQUIDITY();
        flags[4] = hook.CAP_EXTERNAL_HEDGE();
        flags[5] = hook.CAP_EASSET_REBALANCE();
        flags[6] = hook.CAP_BOND_SETTLEMENT();
        flags[7] = hook.CAP_CROSS_CHAIN();
        flags[8] = hook.CAP_ORACLE_REFRESH();

        for (uint256 i; i < flags.length; ++i) {
            assertTrue(flags[i] != 0);
            for (uint256 j = i + 1; j < flags.length; ++j) {
                assertEq(flags[i] & flags[j], 0, "capability collision");
            }
        }
    }

    function _poolKey() internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }
}
