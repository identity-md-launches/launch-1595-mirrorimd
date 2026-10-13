// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MirrorToken} from "../src/MirrorToken.sol";
import {DeployMirrorToken} from "../script/DeployMirrorToken.s.sol";

/// @notice Stands in for the launch factory: a contract that deploys the token and therefore
///         receives the whole supply as `msg.sender` of the creation.
contract DeployerProbe {
    MirrorToken public token;

    function deployToken() external returns (MirrorToken) {
        token = new MirrorToken();
        return token;
    }

    function send(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract MirrorTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    MirrorToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.prank(deployer);
        token = new MirrorToken();
    }

    // ---------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "MirrorIMD");
        assertEq(token.symbol(), "MIRROR");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "MirrorIMD");
        assertEq(token.TOKEN_SYMBOL(), "MIRROR");
    }

    function test_totalSupplyIsExactlyOneBillionTokens() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.SUPPLY_WHOLE_TOKENS(), 1_000_000_000);
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
    }

    function test_wholeSupplyMintedToDeployer() public view {
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsTransferFromZeroAndSupplyMinted() public {
        address other = makeAddr("otherDeployer");
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), other, EXPECTED_SUPPLY);
        vm.expectEmit(true, true, true, true);
        emit MirrorToken.SupplyMinted(other, EXPECTED_SUPPLY);
        vm.prank(other);
        new MirrorToken();
    }

    /// @dev When a contract deploys the token (as the launch factory does), that contract is the
    ///      deployer and holds the whole supply, and can move it on.
    function test_contractDeployerReceivesSupplyAndCanDistribute() public {
        DeployerProbe probe = new DeployerProbe();
        MirrorToken deployed = probe.deployToken();
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
        assertEq(deployed.balanceOf(address(probe)), EXPECTED_SUPPLY);

        uint256 swarm = EXPECTED_SUPPLY / 10;
        assertTrue(probe.send(alice, swarm));
        assertEq(deployed.balanceOf(alice), swarm);
        assertEq(deployed.balanceOf(address(probe)), EXPECTED_SUPPLY - swarm);
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_deployScriptFunctionDeploysTheSameToken() public {
        DeployMirrorToken script = new DeployMirrorToken();
        MirrorToken deployed = script.deploy();
        assertEq(deployed.name(), "MirrorIMD");
        assertEq(deployed.symbol(), "MIRROR");
        assertEq(deployed.decimals(), 18);
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
        // The script contract sent the creation, so it is the deployer and holds the supply.
        assertEq(deployed.balanceOf(address(script)), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------
    // Transfers move exactly what they say
    // ---------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        uint256 amount = 1_234_567 * 1e18;
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferEmitsTransferEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, 5e18);
        vm.prank(deployer);
        token.transfer(alice, 5e18);
    }

    function test_transferChainPreservesAmounts() public {
        uint256 amount = 777e18;
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 1e18));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferWholeSupplySucceeds() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        } else {
            assertEq(token.balanceOf(to), amount);
            assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------
    // Transfer failures
    // ---------------------------------------------------------------------------------------

    function test_revertWhen_transferExceedsBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e18, 11e18));
        vm.prank(alice);
        token.transfer(bob, 11e18);
    }

    function test_revertWhen_strangerWithNoBalanceTransfers() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, 1));
        vm.prank(stranger);
        token.transfer(bob, 1);
    }

    function test_revertWhen_transferToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1e18);
    }

    // ---------------------------------------------------------------------------------------
    // Approvals and transferFrom
    // ---------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, alice, 100e18);
        vm.prank(deployer);
        assertTrue(token.approve(alice, 100e18));
        assertEq(token.allowance(deployer, alice), 100e18);
    }

    function test_transferFromSpendsAllowanceExactly() public {
        vm.prank(deployer);
        token.approve(alice, 100e18);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 60e18));
        assertEq(token.balanceOf(bob), 60e18);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 60e18);
        assertEq(token.allowance(deployer, alice), 40e18);
    }

    function test_transferFromWithMaxAllowanceDoesNotDecrease() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 60e18);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_revertWhen_transferFromExceedsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 50e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 50e18, 51e18));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 51e18);
    }

    function test_revertWhen_transferFromWithoutApproval() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, 1));
        vm.prank(stranger);
        token.transferFrom(deployer, stranger, 1);
    }

    function test_revertWhen_transferFromExceedsOwnerBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        token.approve(bob, 20e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e18, 20e18));
        vm.prank(bob);
        token.transferFrom(alice, stranger, 20e18);
    }

    function test_revertWhen_approveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------
    // No privileged surface: nothing mints, pauses, freezes or seizes
    // ---------------------------------------------------------------------------------------

    function test_noMintOrAdminSelectorsExist() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "burnFrom(address,uint256)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], stranger, type(uint128).max);
            vm.prank(stranger);
            (bool okStranger,) = address(token).call(data);
            assertFalse(okStranger, signatures[i]);
            vm.prank(deployer);
            (bool okDeployer,) = address(token).call(data);
            assertFalse(okDeployer, signatures[i]);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(stranger), 0);
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, 1_000e18);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        // The deployer holds no allowance from alice, so it cannot pull her balance either.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(alice, deployer, 1);

        assertEq(token.balanceOf(alice), 1_000e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 500e18));
        assertEq(token.balanceOf(bob), 500e18);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_plainEtherIsRejected() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }
}
