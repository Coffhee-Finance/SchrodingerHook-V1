// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {
    SchrodingerHyperlaneGateway
} from "../src/reactive/SchrodingerHyperlaneGateway.sol";

import {
    MockHyperlaneMailbox
} from "./mocks/MockHyperlaneMailbox.sol";

import {
    MockSchrodingerMarket
} from "./mocks/MockSchrodingerMarket.sol";

contract SchrodingerHyperlaneGatewayTest is Test {
    uint32 internal constant REACTIVE_DOMAIN = 777_777;

    uint8 internal constant MARKET_TYPE_ERC20 = 1;
    uint8 internal constant MARKET_TYPE_ERC1155 = 2;

    uint8 internal constant ACTION_REBALANCE = 1;

    address internal owner;
    address internal operator;
    address internal reactiveSender;
    address internal unauthorizedUser;

    MockHyperlaneMailbox internal mailbox;

    SchrodingerHyperlaneGateway internal gateway;

    MockSchrodingerMarket internal erc20Market;
    MockSchrodingerMarket internal erc1155Market;

    function setUp() public {
        owner = makeAddr("owner");
        operator = makeAddr("operator");
        reactiveSender = makeAddr("reactiveSender");
        unauthorizedUser = makeAddr("unauthorizedUser");

        mailbox = new MockHyperlaneMailbox();

        gateway = new SchrodingerHyperlaneGateway(
            owner,
            address(mailbox),
            REACTIVE_DOMAIN,
            _addressToBytes32(reactiveSender)
        );

        erc20Market = new MockSchrodingerMarket();
        erc1155Market = new MockSchrodingerMarket();

        erc20Market.setReactiveGateway(
            address(gateway)
        );

        erc1155Market.setReactiveGateway(
            address(gateway)
        );

        vm.startPrank(owner);

        gateway.registerMarket(
            address(erc20Market),
            MARKET_TYPE_ERC20
        );

        gateway.registerMarket(
            address(erc1155Market),
            MARKET_TYPE_ERC1155
        );

        gateway.setSignalOperator(
            operator,
            true
        );

        gateway.setAllowedSelector(
            address(erc20Market),
            MockSchrodingerMarket
                .executeReactiveRebalance
                .selector,
            true
        );

        gateway.setAllowedSelector(
            address(erc1155Market),
            MockSchrodingerMarket
                .executeReactiveRebalance
                .selector,
            true
        );

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function testDeploymentConfiguration()
        public
        view
    {
        assertEq(
            gateway.owner(),
            owner
        );

        assertEq(
            gateway.mailbox(),
            address(mailbox)
        );

        assertEq(
            gateway.trustedReactiveDomain(),
            REACTIVE_DOMAIN
        );

        assertEq(
            gateway.trustedReactiveSender(),
            _addressToBytes32(reactiveSender)
        );

        assertEq(
            gateway.MESSAGE_VERSION(),
            1
        );

        assertEq(
            gateway.MARKET_TYPE_ERC20(),
            MARKET_TYPE_ERC20
        );

        assertEq(
            gateway.MARKET_TYPE_ERC1155(),
            MARKET_TYPE_ERC1155
        );
    }

    function testRevertDeploymentWithZeroMailbox()
        public
    {
        vm.expectRevert(
            SchrodingerHyperlaneGateway
                .ZeroAddress
                .selector
        );

        new SchrodingerHyperlaneGateway(
            owner,
            address(0),
            REACTIVE_DOMAIN,
            _addressToBytes32(reactiveSender)
        );
    }

    /*//////////////////////////////////////////////////////////////
                       MARKET REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function testERC20MarketIsRegistered()
        public
        view
    {
        (
            bool registered,
            bool active,
            uint8 marketType
        ) = gateway.markets(
            address(erc20Market)
        );

        assertTrue(registered);
        assertTrue(active);

        assertEq(
            marketType,
            MARKET_TYPE_ERC20
        );
    }

    function testERC1155MarketIsRegistered()
        public
        view
    {
        (
            bool registered,
            bool active,
            uint8 marketType
        ) = gateway.markets(
            address(erc1155Market)
        );

        assertTrue(registered);
        assertTrue(active);

        assertEq(
            marketType,
            MARKET_TYPE_ERC1155
        );
    }

    function testOwnerCanRegisterNewMarket()
        public
    {
        MockSchrodingerMarket newMarket =
            new MockSchrodingerMarket();

        vm.prank(owner);

        gateway.registerMarket(
            address(newMarket),
            MARKET_TYPE_ERC20
        );

        (
            bool registered,
            bool active,
            uint8 marketType
        ) = gateway.markets(
            address(newMarket)
        );

        assertTrue(registered);
        assertTrue(active);

        assertEq(
            marketType,
            MARKET_TYPE_ERC20
        );
    }

    function testNonOwnerCannotRegisterMarket()
        public
    {
        MockSchrodingerMarket newMarket =
            new MockSchrodingerMarket();

        vm.prank(unauthorizedUser);

        vm.expectRevert();

        gateway.registerMarket(
            address(newMarket),
            MARKET_TYPE_ERC20
        );
    }

    function testRevertRegisteringZeroMarket()
        public
    {
        vm.prank(owner);

        vm.expectRevert(
            SchrodingerHyperlaneGateway
                .ZeroAddress
                .selector
        );

        gateway.registerMarket(
            address(0),
            MARKET_TYPE_ERC20
        );
    }

    function testRevertRegisteringInvalidMarketType()
        public
    {
        MockSchrodingerMarket newMarket =
            new MockSchrodingerMarket();

        uint8 invalidMarketType = 99;

        vm.prank(owner);

        vm.expectRevert(
            abi.encodeWithSelector(
                SchrodingerHyperlaneGateway
                    .InvalidMarketType
                    .selector,
                invalidMarketType
            )
        );

        gateway.registerMarket(
            address(newMarket),
            invalidMarketType
        );
    }

    function testOwnerCanDeactivateMarket()
        public
    {
        vm.prank(owner);

        gateway.setMarketActive(
            address(erc20Market),
            false
        );

        (
            bool registered,
            bool active,
            uint8 marketType
        ) = gateway.markets(
            address(erc20Market)
        );

        assertTrue(registered);
        assertFalse(active);

        assertEq(
            marketType,
            MARKET_TYPE_ERC20
        );
    }

    function testRevertUpdatingUnknownMarket()
        public
    {
        address unknownMarket =
            makeAddr("unknownMarket");

        vm.prank(owner);

        vm.expectRevert(
            abi.encodeWithSelector(
                SchrodingerHyperlaneGateway
                    .MarketNotRegistered
                    .selector,
                unknownMarket
            )
        );

        gateway.setMarketActive(
            unknownMarket,
            false
        );
    }

    /*//////////////////////////////////////////////////////////////
                        SIGNAL OPERATORS
    //////////////////////////////////////////////////////////////*/

    function testOwnerCanSetSignalOperator()
        public
    {
        address newOperator =
            makeAddr("newOperator");

        vm.prank(owner);

        gateway.setSignalOperator(
            newOperator,
            true
        );

        assertTrue(
            gateway.signalOperators(
                newOperator
            )
        );

        vm.prank(owner);

        gateway.setSignalOperator(
            newOperator,
            false
        );

        assertFalse(
            gateway.signalOperators(
                newOperator
            )
        );
    }

    function testRevertSettingZeroSignalOperator()
        public
    {
        vm.prank(owner);

        vm.expectRevert(
            SchrodingerHyperlaneGateway
                .ZeroAddress
                .selector
        );

        gateway.setSignalOperator(
            address(0),
            true
        );
    }

    /*//////////////////////////////////////////////////////////////
                      SELECTOR PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function testSelectorIsApprovedForERC20Market()
        public
        view
    {
        assertTrue(
            gateway.allowedSelectors(
                address(erc20Market),
                MockSchrodingerMarket
                    .executeReactiveRebalance
                    .selector
            )
        );
    }

    function testSelectorIsApprovedForERC1155Market()
        public
        view
    {
        assertTrue(
            gateway.allowedSelectors(
                address(erc1155Market),
                MockSchrodingerMarket
                    .executeReactiveRebalance
                    .selector
            )
        );
    }

    function testOwnerCanDisableSelector()
        public
    {
        bytes4 selector =
            MockSchrodingerMarket
                .executeReactiveRebalance
                .selector;

        vm.prank(owner);

        gateway.setAllowedSelector(
            address(erc20Market),
            selector,
            false
        );

        assertFalse(
            gateway.allowedSelectors(
                address(erc20Market),
                selector
            )
        );
    }

    function testRevertSettingSelectorForUnknownMarket()
        public
    {
        address unknownMarket =
            makeAddr("unknownMarket");

        vm.prank(owner);

        vm.expectRevert(
            abi.encodeWithSelector(
                SchrodingerHyperlaneGateway
                    .MarketNotRegistered
                    .selector,
                unknownMarket
            )
        );

        gateway.setAllowedSelector(
            unknownMarket,
            MockSchrodingerMarket
                .executeReactiveRebalance
                .selector,
            true
        );
    }

    /*//////////////////////////////////////////////////////////////
                        TRUSTED ENDPOINT
    //////////////////////////////////////////////////////////////*/

    function testOwnerCanUpdateTrustedReactiveEndpoint()
        public
    {
        uint32 newDomain = 123_456;

        address newSender =
            makeAddr("newReactiveSender");

        vm.prank(owner);

        gateway.setTrustedReactiveEndpoint(
            newDomain,
            _addressToBytes32(newSender)
        );

        assertEq(
            gateway.trustedReactiveDomain(),
            newDomain
        );

        assertEq(
            gateway.trustedReactiveSender(),
            _addressToBytes32(newSender)
        );
    }

    function testNonOwnerCannotUpdateTrustedEndpoint()
        public
    {
        vm.prank(unauthorizedUser);

        vm.expectRevert();

        gateway.setTrustedReactiveEndpoint(
            123,
            bytes32(uint256(1))
        );
    }

    /*//////////////////////////////////////////////////////////////
                    ERC20 SIGNAL PUBLISHING
    //////////////////////////////////////////////////////////////*/

    function testPublishSignalForERC20Market()
        public
    {
        bytes32 marketId =
            keccak256("erc20-market");

        bytes memory rebalanceData =
            abi.encode(
                uint256(125),
                uint256(75)
            );

        bytes memory callData =
            abi.encodeCall(
                MockSchrodingerMarket
                    .executeReactiveRebalance,
                (
                    marketId,
                    rebalanceData
                )
            );

        vm.prank(operator);

        (
            uint256 nonce,
            bytes memory envelope
        ) = gateway.publishSignalFor(
            address(erc20Market),
            marketId,
            ACTION_REBALANCE,
            callData
        );

        assertEq(
            nonce,
            1
        );

        assertEq(
            gateway.signalNonce(),
            1
        );

        SchrodingerHyperlaneGateway
            .MarketSignal memory signal =
                abi.decode(
                    envelope,
                    (
                        SchrodingerHyperlaneGateway
                            .MarketSignal
                    )
                );

        assertEq(
            signal.version,
            gateway.MESSAGE_VERSION()
        );

        assertEq(
            signal.sourceChainId,
            block.chainid
        );

        assertEq(
            signal.sourceGateway,
            address(gateway)
        );

        assertEq(
            signal.sourceMarket,
            address(erc20Market)
        );

        assertEq(
            signal.marketType,
            MARKET_TYPE_ERC20
        );

        assertEq(
            signal.marketId,
            marketId
        );

        assertEq(
            signal.action,
            ACTION_REBALANCE
        );

        assertEq(
            signal.nonce,
            1
        );

        assertEq(
            signal.timestamp,
            block.timestamp
        );

        assertEq(
            signal.callbackData,
            callData
        );
    }

    function testMarketCanPublishItsOwnSignal()
        public
    {
        bytes32 marketId =
            keccak256("self-published-market");

        bytes memory callData =
            abi.encodeCall(
                MockSchrodingerMarket
                    .executeReactiveRebalance,
                (
                    marketId,
                    bytes("self-published")
                )
            );

        vm.prank(
            address(erc20Market)
        );

        (
            uint256 nonce,
            bytes memory envelope
        ) = gateway.publishSignal(
            marketId,
            ACTION_REBALANCE,
            callData
        );

        assertEq(
            nonce,
            1
        );

        SchrodingerHyperlaneGateway
            .MarketSignal memory signal =
                abi.decode(
                    envelope,
                    (
                        SchrodingerHyperlaneGateway
                            .MarketSignal
                    )
                );

        assertEq(
            signal.sourceMarket,
            address(erc20Market)
        );
    }

    function testUnauthorizedUserCannotPublishSignalForMarket()
        public
    {
        bytes32 marketId =
            keccak256("unauthorized");

        bytes memory callData =
            abi.encodeCall(
                MockSchrodingerMarket
                    .executeReactiveRebalance,
                (
                    marketId,
                    bytes("data")
                )
            );

        vm.prank(unauthorizedUser);

        vm.expectRevert(
            abi.encodeWithSelector(
                SchrodingerHyperlaneGateway
                    .UnauthorizedPublisher
                    .selector,
                unauthorizedUser,
                address(erc20Market)
            )
        );

        gateway.publishSignalFor(
            address(erc20Market),
            marketId,
            ACTION_REBALANCE,
            callData
        );
    }

    function testCannotPublishForInactiveMarket()
        public
    {
        vm.prank(owner);

        gateway.setMarketActive(
            address(erc20Market),
            false
        );

        bytes32 marketId =
            keccak256("inactive-market");

        bytes memory callData =
            abi.encodeCall(
                MockSchrodingerMarket
                    .executeReactiveRebalance,
                (
                    marketId,
                    bytes("data")
                )
            );

        vm.prank(operator);

        vm.expectRevert(
            abi.encodeWithSelector(
                SchrodingerHyperlaneGateway
                    .MarketNotActive
                    .selector,
                address(erc20Market)
            )
        );

        gateway.publishSignalFor(
            address(erc20Market),
            marketId,
            ACTION_REBALANCE,
            callData
        );
    }

    /*//////////////////////////////////////////////////////////////
                   ERC1155 SIGNAL PUBLISHING
    //////////////////////////////////////////////////////////////*/

    function testPublishSignalForERC1155Market()
        public
    {
        bytes32 marketId =
            keccak256("erc1155-market");

        bytes memory callData =
            abi.encodeCall(
                MockSchrodingerMarket
                    .executeReactiveRebalance,
                (
                    marketId,
                    abi.encode(
                        uint256(42)
                    )
                )
            );

        vm.prank(operator);

        (
            ,
            bytes memory envelope
        ) = gateway.publishSignalFor(
            address(erc1155Market),
            marketId,
            ACTION_REBALANCE,
            callData
        );

        SchrodingerHyperlaneGateway
            .MarketSignal memory signal =
                abi.decode(
                    envelope,
                    (
                        SchrodingerHyperlaneGateway
                            .MarketSignal
                    )
                );

        assertEq(
            signal.sourceMarket,
            address(erc1155Market)
        );

        assertEq(
            signal.marketType,
            MARKET_TYPE_ERC1155
        );

        assertEq(
            signal.marketId,
            marketId
        );
    }

    /*//////////////////////////////////////////////////////////////
                   ERC20 COMMAND EXECUTION
    //////////////////////////////////////////////////////////////*/

    function testHandleExecutesApprovedERC20Command()
        public
    {
        bytes32 marketId =
            keccak256("erc20-market");

        bytes memory rebalanceData =
            abi.encode(
                "private-strategy"
            );

        bytes memory callData =
            abi.encodeCall(
                MockSchrodingerMarket
                    .executeReactiveRebalance,
                (
                    marketId,
                    rebalanceData
                )
            );

        bytes32 commandId =
            keccak256("command-1");

        SchrodingerHyperlaneGateway
            .ReactiveCommand memory command =
                SchrodingerHyperlaneGateway
                    .ReactiveCommand({
                        version:
                            gateway
                                .MESSAGE_VERSION(),
                        commandId:
                            commandId,
                        targetMarket:
                            address(
                                erc20Market
                            ),
                        marketType:
                            MARKET_TYPE_ERC20,
                        marketId:
                            marketId,
                        action:
                            ACTION_REBALANCE,
                        signalNonce:
                            1,
                        callData:
                            callData
                    });

        mailbox.deliver(
            address(gateway),
            REACTIVE_DOMAIN,
            _addressToBytes32(
                reactiveSender
            ),
            abi.encode(command)
        );

        assertTrue(
            gateway.processedCommands(
                commandId
            )
        );

        assertEq(
            erc20Market.executionCount(),
            1
        );

        assertEq(
            erc20Market.lastMarketId(),
            marketId
        );

        assertEq(
            erc20Market.lastRebalanceData(),
            rebalanceData
        );
    }

    /*//////////////////////////////////////////////////////////////
                  ERC1155 COMMAND EXECUTION
    //////////////////////////////////////////////////////////////*/

    function testHandleExecutesApprovedERC1155Command()
        public
    {
        bytes32 marketId =
            keccak256("erc1155-market");

        bytes memory rebalanceData =
            abi.encode(
                uint256(3475),
                uint256(1155)
            );

        bytes memory callData =
            abi.encodeCall(
                MockSchrodingerMarket
                    .executeReactiveRebalance,
                (
                    marketId,
                    rebalanceData
                )
            );

        SchrodingerHyperlaneGateway
            .ReactiveCommand memory command =
                _command(
                    keccak256(
                        "command-1155"
                    ),
                    address(
                        erc1155Market
                    ),
                    MARKET_TYPE_ERC1155,
                    marketId,
                    2,
                    callData
                );

        mailbox.deliver(
            address(gateway),
            REACTIVE_DOMAIN,
            _addressToBytes32(
                reactiveSender
            ),
            abi.encode(command)
        );

        assertEq(
            erc1155Market.executionCount(),
            1
        );

        assertEq(
            erc1155Market.lastMarketId(),
            marketId
        );

        assertEq(
            erc1155Market
                .lastRebalanceData(),
            rebalanceData
        );
    }

    /*//////////////////////////////////////////////////////////////
                      MAILBOX AUTHENTICATION
    //////////////////////////////////////////////////////////////*/

    function testRevertsWhenCallerIsNotMailbox()
        public
    {
        SchrodingerHyperlaneGateway
            .ReactiveCommand memory command =
                _validERC20Command(
                    keccak256(
                        "not-mailbox"
                    )
                );

        vm.expectRevert(
            abi.encodeWithSelector(
                SchrodingerHyperlaneGateway
                    .OnlyMailbox
                    .selector,
                address(this)
            )
        );

        gateway.handle(
            REACTIVE_DOMAIN,
            _addressToBytes32(
                reactiveSender
            ),
            abi.encode(command)
        );
    }

    function testRevertsForWrongReactiveDomain()
        public
    {
        SchrodingerHyperlaneGateway
            .ReactiveCommand memory command =
                _validERC20Command(
                    keccak256(
                        "wrong-domain"
                    )
                );

        vm.expectRevert(
            abi.encodeWithSelector(
                SchrodingerHyperlaneGateway
                    .InvalidReactiveDomain
                    .selector,
                REACTIVE_DOMAIN + 1,
                REACTIVE_DOMAIN
            )
        );

        mailbox.deliver(
            address(gateway),
            REACTIVE_DOMAIN + 1,
            _addressToBytes32(
                reactiveSender
            ),
            abi.encode(command)
        );
    }

    function testRevertsForWrongReactiveSender()
        public
    {
        address attacker =
            makeAddr("attacker");

        SchrodingerHyperlaneGateway
            .ReactiveCommand memory command =
                _validERC20Command(
                    keccak256(
                        "wrong-sender"
                    )
                );

        vm.expectRevert(
            abi.encodeWithSelector(
                SchrodingerHyperlaneGateway
                    .InvalidReactiveSender
                    .selector,
                _addressToBytes32(
                    attacker
                ),
                _addressToBytes32(
                    reactiveSender
                )
            )
        );

        mailbox.deliver(
            address(gateway),
            REACTIVE_DOMAIN,
            _addressToBytes32(attacker),
            abi.encode(command)
        );
    }

    /*//////////////////////////////////////////////////////////////
                     COMMAND VALIDATION
    //////////////////////////////////////////////////////////////*/

    function testRevertsForUnsupportedMessageVersion()
        public
    {
        SchrodingerHyperlaneGateway
            .ReactiveCommand memory command =
                _validERC20Command(
                    keccak256(
                        "wrong-version"
                    )
                );

        command.version = 99;

        vm.expectRevert(
            abi.encodeWithSelector(
                SchrodingerHyperlaneGateway
                    .UnsupportedMessageVersion
                    .selector,
                99
            )
        );

        mailbox.deliver(
            address(gateway),
            REACTIVE_DOMAIN,
            _addressToBytes32(
                reactiveSender
            ),
            abi.encode(command)
        );
    }

    function testRevertsForUnknownTargetMarket()
        public
    {
        address unknownMarket =
            makeAddr("unknownMarket");

        bytes32 marketId =
            keccak256("unknown-market");

        SchrodingerHyperlaneGateway
            .ReactiveCommand memory command =
                _command(
                    keccak256(
                        "unknown-target"
                    ),
                    unknownMarket,
                    MARKET_TYPE_ERC20,
                    marketId,
                    1,
                    abi.encodeCall(
                        MockSchrodingerMarket
                            .executeReactiveRebalance,
                        (
                            marketId,
                            bytes("data")
                        )
                    )
                );

        vm.expectRevert(
            abi.encodeWithSelector(
                SchrodingerHyperlaneGateway
                    .MarketNotRegistered
                    .selector,
                unknownMarket
            )
        );

        mailbox.deliver(
            address(gateway),
            REACTIVE_DOMAIN,
            _addressToBytes32(
                reactiveSender
            ),
            abi.encode(command)
        );
    }

    function testRevertsForInactiveTargetMarket()
        public
    {
        vm.prank(owner);

        gateway.setMarketActive(
            address(erc20Market),
            false
        );

        SchrodingerHyperlaneGateway
            .ReactiveCommand memory command =
                _validERC20Command(
                    keccak256(
                        "inactive-target"
                    )
                );

        vm.expectRevert(
            abi.encodeWithSelector(
                SchrodingerHyperlaneGateway
                    .MarketNotActive
                    .selector,
                address(erc20Market)
            )
        );

        mailbox.deliver(
            address(gateway),
            REACTIVE_DOMAIN,
            _addressToBytes32(
                reactiveSender
            ),
            abi.encode(command)
        );
    }

    function testRevertsForMarketTypeMismatch()
        public
    {
        SchrodingerHyperlaneGateway
            .ReactiveCommand memory command =
                _validERC20Command(
                    keccak256(
                        "type-mismatch"
                    )
                );

        command.marketType =
            MARKET_TYPE_ERC1155;

        vm.expectRevert(
            abi.encodeWithSelector(
                SchrodingerHyperlaneGateway
                    .MarketTypeMismatch
                    .selector,
                MARKET_TYPE_ERC1155,
                MARKET_TYPE_ERC20
            )
        );

        mailbox.deliver(
            address(gateway),
            REACTIVE_DOMAIN,
            _addressToBytes32(
                reactiveSender
            ),
            abi.encode(command)
        );
    }

    function testRevertsForEmptyCallData()
        public
    {
        SchrodingerHyperlaneGateway
            .ReactiveCommand memory command =
                _command(
                    keccak256(
                        "empty-calldata"
                    ),
                    address(erc20Market),
                    MARKET_TYPE_ERC20,
                    keccak256("market"),
                    1,
                    bytes("")
                );

        vm.expectRevert(
            SchrodingerHyperlaneGateway
                .EmptyCallData
                .selector
        );

        mailbox.deliver(
            address(gateway),
            REACTIVE_DOMAIN,
            _addressToBytes32(
                reactiveSender
            ),
            abi.encode(command)
        );
    }

    function testRevertsForShortCallData()
        public
    {
        SchrodingerHyperlaneGateway
            .ReactiveCommand memory command =
                _command(
                    keccak256(
                        "short-calldata"
                    ),
                    address(erc20Market),
                    MARKET_TYPE_ERC20,
                    keccak256("market"),
                    1,
                    hex"1234"
                );

        vm.expectRevert(
            SchrodingerHyperlaneGateway
                .EmptyCallData
                .selector
        );

        mailbox.deliver(
            address(gateway),
            REACTIVE_DOMAIN,
            _addressToBytes32(
                reactiveSender
            ),
            abi.encode(command)
        );
    }

    function testRevertsForUnapprovedSelector()
        public
    {
        bytes memory callData =
            abi.encodeCall(
                MockSchrodingerMarket
                    .unapprovedFunction,
                (123)
            );

        SchrodingerHyperlaneGateway
            .ReactiveCommand memory command =
                _command(
                    keccak256(
                        "bad-selector"
                    ),
                    address(erc20Market),
                    MARKET_TYPE_ERC20,
                    keccak256("market"),
                    1,
                    callData
                );

        vm.expectRevert(
            abi.encodeWithSelector(
                SchrodingerHyperlaneGateway
                    .SelectorNotAllowed
                    .selector,
                address(erc20Market),
                MockSchrodingerMarket
                    .unapprovedFunction
                    .selector
            )
        );

        mailbox.deliver(
            address(gateway),
            REACTIVE_DOMAIN,
            _addressToBytes32(
                reactiveSender
            ),
            abi.encode(command)
        );
    }

    /*//////////////////////////////////////////////////////////////
                         REPLAY PROTECTION
    //////////////////////////////////////////////////////////////*/

    function testRevertsOnReplay()
        public
    {
        bytes32 commandId =
            keccak256("replay");

        SchrodingerHyperlaneGateway
            .ReactiveCommand memory command =
                _validERC20Command(
                    commandId
                );

        bytes memory body =
            abi.encode(command);

        mailbox.deliver(
            address(gateway),
            REACTIVE_DOMAIN,
            _addressToBytes32(
                reactiveSender
            ),
            body
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                SchrodingerHyperlaneGateway
                    .CommandAlreadyProcessed
                    .selector,
                commandId
            )
        );

        mailbox.deliver(
            address(gateway),
            REACTIVE_DOMAIN,
            _addressToBytes32(
                reactiveSender
            ),
            body
        );
    }

    function test_RevertWhenFailedCommandDoesNotRemainProcessed()
        public
    {
        bytes32 commandId =
            keccak256("failed-command");

        bytes memory callData =
            abi.encodeCall(
                MockSchrodingerMarket
                    .unapprovedFunction,
                (123)
            );

        SchrodingerHyperlaneGateway
            .ReactiveCommand memory command =
                _command(
                    commandId,
                    address(erc20Market),
                    MARKET_TYPE_ERC20,
                    keccak256("market"),
                    1,
                    callData
                );

        vm.expectRevert();

        mailbox.deliver(
            address(gateway),
            REACTIVE_DOMAIN,
            _addressToBytes32(
                reactiveSender
            ),
            abi.encode(command)
        );

        assertFalse(
            gateway.processedCommands(
                commandId
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                         ENCODING HELPERS
    //////////////////////////////////////////////////////////////*/

    function testEncodeAndDecodeSignal()
        public
        view
    {
        SchrodingerHyperlaneGateway
            .MarketSignal memory signal =
                SchrodingerHyperlaneGateway
                    .MarketSignal({
                        version:
                            gateway
                                .MESSAGE_VERSION(),
                        sourceChainId:
                            block.chainid,
                        sourceGateway:
                            address(gateway),
                        sourceMarket:
                            address(
                                erc20Market
                            ),
                        marketType:
                            MARKET_TYPE_ERC20,
                        marketId:
                            keccak256(
                                "market"
                            ),
                        action:
                            ACTION_REBALANCE,
                        nonce:
                            1,
                        timestamp:
                            block.timestamp,
                        callbackData:
                            bytes("callback")
                    });

        bytes memory encoded =
            gateway.encodeSignal(signal);

        SchrodingerHyperlaneGateway
            .MarketSignal memory decoded =
                gateway.decodeSignal(
                    encoded
                );

        assertEq(
            decoded.version,
            signal.version
        );

        assertEq(
            decoded.sourceMarket,
            signal.sourceMarket
        );

        assertEq(
            decoded.marketId,
            signal.marketId
        );

        assertEq(
            decoded.callbackData,
            signal.callbackData
        );
    }

    function testEncodeAndDecodeCommand()
        public
        view
    {
        SchrodingerHyperlaneGateway
            .ReactiveCommand memory command =
                _validERC20Command(
                    keccak256(
                        "encode-command"
                    )
                );

        bytes memory encoded =
            gateway.encodeCommand(
                command
            );

        SchrodingerHyperlaneGateway
            .ReactiveCommand memory decoded =
                gateway.decodeCommand(
                    encoded
                );

        assertEq(
            decoded.commandId,
            command.commandId
        );

        assertEq(
            decoded.targetMarket,
            command.targetMarket
        );

        assertEq(
            decoded.marketType,
            command.marketType
        );

        assertEq(
            decoded.callData,
            command.callData
        );
    }

    function testAddressToBytes32()
        public
        view
    {
        assertEq(
            gateway.addressToBytes32(
                reactiveSender
            ),
            _addressToBytes32(
                reactiveSender
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                             HELPERS
    //////////////////////////////////////////////////////////////*/

    function _validERC20Command(
        bytes32 commandId
    )
        internal
        view
        returns (
            SchrodingerHyperlaneGateway
                .ReactiveCommand memory
        )
    {
        bytes32 marketId =
            keccak256("erc20-market");

        return _command(
            commandId,
            address(erc20Market),
            MARKET_TYPE_ERC20,
            marketId,
            1,
            abi.encodeCall(
                MockSchrodingerMarket
                    .executeReactiveRebalance,
                (
                    marketId,
                    bytes("rebalance")
                )
            )
        );
    }

    function _command(
        bytes32 commandId,
        address target,
        uint8 marketType,
        bytes32 marketId,
        uint256 signalNonce,
        bytes memory callData
    )
        internal
        view
        returns (
            SchrodingerHyperlaneGateway
                .ReactiveCommand memory
        )
    {
        return SchrodingerHyperlaneGateway
            .ReactiveCommand({
                version:
                    gateway
                        .MESSAGE_VERSION(),
                commandId:
                    commandId,
                targetMarket:
                    target,
                marketType:
                    marketType,
                marketId:
                    marketId,
                action:
                    ACTION_REBALANCE,
                signalNonce:
                    signalNonce,
                callData:
                    callData
            });
    }

    function _addressToBytes32(
        address account
    )
        internal
        pure
        returns (bytes32)
    {
        return bytes32(
            uint256(
                uint160(account)
            )
        );
    }
}