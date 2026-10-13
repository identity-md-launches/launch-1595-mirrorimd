// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MirrorToken} from "../src/MirrorToken.sol";

/// @title Stateless property tests and pinned edge cases for MirrorToken.
/// @notice Round-trips, idempotence, path-independence and exact-error failure paths, fuzzed at
///         the edges of the arithmetic and pinned at the values already known to matter: zero,
///         one wei, the whole supply, max and max minus one.
/// forge-config: default.fuzz.runs = 1000
contract MirrorTokenPropertyTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant MAX = type(uint256).max;

    MirrorToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        vm.prank(deployer);
        token = new MirrorToken();
    }

    function _fund(address who, uint256 amount) internal {
        vm.prank(deployer);
        token.transfer(who, amount);
    }

    /// @dev Keeps a fuzzed address away from the special parties so balances are attributable.
    function _ordinary(address a) internal view returns (address) {
        if (a == address(0) || a == deployer || a == alice || a == bob || a == address(token)) {
            return address(uint160(uint256(keccak256(abi.encode(a)))));
        }
        return a;
    }

    // ---------------------------------------------------------------------------------------
    // Deployment properties
    // ---------------------------------------------------------------------------------------

    /// @dev Whoever sends the creation gets the whole supply: fuzzed over the deployer address.
    function testFuzz_anyDeployerReceivesWholeSupply(address who) public {
        who = _ordinary(who);
        vm.prank(who);
        MirrorToken fresh = new MirrorToken();
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(who), SUPPLY);
        assertEq(fresh.balanceOf(deployer), 0);
    }

    /// @dev Deployments are independent: a second token does not share state with the first.
    function test_secondDeploymentIsIndependent() public {
        vm.prank(alice);
        MirrorToken second = new MirrorToken();
        assertTrue(address(second) != address(token));
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(second.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_supplyConstantsAgreeWithDecimals() public view {
        assertEq(token.TOTAL_SUPPLY(), token.SUPPLY_WHOLE_TOKENS() * 10 ** token.decimals());
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    /// @dev The constructor emits exactly two logs: the ERC-20 Transfer from zero, then SupplyMinted.
    function test_constructorEmitsExactlyTwoLogs() public {
        vm.recordLogs();
        vm.prank(alice);
        MirrorToken fresh = new MirrorToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(0)))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(logs[1].emitter, address(fresh));
        assertEq(logs[1].topics[0], MirrorToken.SupplyMinted.selector);
        assertEq(logs[1].topics[1], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[1].data, (uint256)), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------
    // Transfer properties
    // ---------------------------------------------------------------------------------------

    /// @dev Round-trip: a -> b -> a restores both balances exactly.
    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Path independence: one transfer of x+y equals a transfer of x followed by y.
    function testFuzz_transferIsPathIndependent(uint256 x, uint256 y) public {
        x = bound(x, 0, SUPPLY);
        y = bound(y, 0, SUPPLY - x);

        vm.prank(alice);
        MirrorToken single = new MirrorToken();
        vm.prank(alice);
        single.transfer(bob, x + y);

        vm.prank(alice);
        MirrorToken split = new MirrorToken();
        vm.startPrank(alice);
        split.transfer(bob, x);
        split.transfer(bob, y);
        vm.stopPrank();

        assertEq(single.balanceOf(bob), split.balanceOf(bob));
        assertEq(single.balanceOf(alice), split.balanceOf(alice));
        assertEq(single.balanceOf(bob), x + y);
    }

    /// @dev Transfers to third parties do not touch anyone else's balance or any allowance.
    function testFuzz_transferIsIsolated(address to, uint256 amount, uint256 allowance) public {
        to = _ordinary(to);
        amount = bound(amount, 0, SUPPLY - 1e18);
        vm.prank(deployer);
        token.approve(bob, allowance);
        _fund(alice, 1e18);

        vm.prank(deployer);
        token.transfer(to, amount);

        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(alice), 1e18);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(deployer, bob), allowance);
        assertEq(token.allowance(deployer, to), 0);
    }

    /// @dev A sequence of bounded transfers among a small set of holders conserves the supply.
    function testFuzz_transferSequenceConservesSupply(uint256[8] memory seeds) public {
        address[4] memory holders = [deployer, alice, bob, carol];
        for (uint256 i = 0; i < seeds.length; i++) {
            address from = holders[seeds[i] % 4];
            address to = holders[(seeds[i] >> 8) % 4];
            uint256 amount = (seeds[i] >> 16) % (token.balanceOf(from) + 1);
            vm.prank(from);
            assertTrue(token.transfer(to, amount));
        }
        uint256 sum;
        for (uint256 i = 0; i < holders.length; i++) {
            sum += token.balanceOf(holders[i]);
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Any sender with no balance cannot move even one wei, whoever they are.
    function testFuzz_strangerCannotTransferOneWei(address stranger, address to) public {
        stranger = _ordinary(stranger);
        to = _ordinary(to);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, 1));
        vm.prank(stranger);
        token.transfer(to, 1);
    }

    /// @dev Exactly one wei over the balance fails, for any balance: the boundary is tight.
    function testFuzz_transferOneWeiOverBalanceReverts(uint256 balance) public {
        balance = bound(balance, 0, SUPPLY - 1);
        _fund(alice, balance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, balance + 1)
        );
        vm.prank(alice);
        token.transfer(bob, balance + 1);
        // And exactly the balance succeeds.
        vm.prank(alice);
        assertTrue(token.transfer(bob, balance));
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev A transfer of max uint from the deployer fails without wrapping anything.
    function test_transferMaxUintReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, MAX));
        vm.prank(deployer);
        token.transfer(alice, MAX);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferOneWeiMovesOneWei() public {
        vm.prank(deployer);
        token.transfer(alice, 1);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(deployer), SUPPLY - 1);
    }

    /// @dev msg.sender == address(0) is rejected as a sender even for zero value.
    function test_revertWhen_zeroAddressTransfers() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(alice, 0);
    }

    /// @dev Zero-value transfer to the zero address still fails: the receiver check is unconditional.
    function test_revertWhen_zeroValueTransferToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transfer(address(0), 0);
    }

    /// @dev Transfers to the token's own address are allowed by ERC-20 and the balance is simply
    ///      stuck there: the contract has no function to move it. Documented behaviour, pinned so a
    ///      future change is noticed.
    function test_transferToTokenAddressIsAcceptedAndStranded() public {
        vm.prank(deployer);
        assertTrue(token.transfer(address(token), 5e18));
        assertEq(token.balanceOf(address(token)), 5e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------
    // Approval properties
    // ---------------------------------------------------------------------------------------

    /// @dev approve overwrites: the allowance equals the last value set, never a sum.
    function testFuzz_approveOverwritesNotAccumulates(uint256 first, uint256 second) public {
        vm.startPrank(deployer);
        token.approve(alice, first);
        assertEq(token.allowance(deployer, alice), first);
        token.approve(alice, second);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), second);
    }

    /// @dev approve is idempotent: calling it twice with the same value is one call.
    function testFuzz_approveIsIdempotent(uint256 amount) public {
        vm.startPrank(deployer);
        token.approve(alice, amount);
        token.approve(alice, amount);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), amount);
    }

    /// @dev An approval is scoped to one (owner, spender) pair and to no balance.
    function testFuzz_approveIsIsolated(address spender, uint256 amount) public {
        spender = _ordinary(spender);
        vm.prank(alice); // alice holds nothing; allowances are independent of balances
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(alice, spender), amount);
        assertEq(token.allowance(spender, alice), 0);
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Approving does not move value; only transferFrom does, and only up to the balance.
    function testFuzz_approvalWithoutBalanceCannotBeSpent(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 1, MAX);
        amount = bound(amount, 1, allowance);
        vm.prank(alice);
        token.approve(bob, allowance);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, amount));
        vm.prank(bob);
        token.transferFrom(alice, carol, amount);
    }

    function test_revertWhen_zeroAddressApproves() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(alice, 1);
    }

    function test_approveSelfAsSpenderWorksAndIsSpendable() public {
        vm.prank(deployer);
        token.approve(deployer, 3e18);
        vm.prank(deployer);
        assertTrue(token.transferFrom(deployer, alice, 3e18));
        assertEq(token.balanceOf(alice), 3e18);
        assertEq(token.allowance(deployer, deployer), 0);
    }

    function test_approveZeroClearsAllowance() public {
        vm.startPrank(deployer);
        token.approve(alice, 7e18);
        token.approve(alice, 0);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
    }

    // ---------------------------------------------------------------------------------------
    // transferFrom properties
    // ---------------------------------------------------------------------------------------

    /// @dev For every finite allowance and amount within it, the allowance decreases by exactly
    ///      the amount and the balances move by exactly the amount.
    function testFuzz_transferFromSpendsExactly(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, MAX - 1);
        amount = bound(amount, 0, allowance < SUPPLY ? allowance : SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowance);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, amount));
        assertEq(token.allowance(deployer, alice), allowance - amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(alice), 0, "the spender must not receive anything");
    }

    /// @dev Only exactly max is infinite: max minus one is an ordinary allowance and is decremented.
    function test_maxMinusOneAllowanceIsDecremented() public {
        vm.prank(deployer);
        token.approve(alice, MAX - 1);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), MAX - 2);
    }

    /// @dev An infinite allowance can move the whole supply repeatedly and never shrinks.
    function testFuzz_infiniteAllowanceSurvivesAnySpend(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, MAX);
        vm.prank(alice);
        token.transferFrom(deployer, bob, amount);
        assertEq(token.allowance(deployer, alice), MAX);
        vm.prank(alice);
        token.transferFrom(deployer, bob, SUPPLY - amount);
        assertEq(token.allowance(deployer, alice), MAX);
        assertEq(token.balanceOf(bob), SUPPLY);
    }

    /// @dev Spending the whole allowance leaves exactly zero, and one more wei is refused.
    function testFuzz_spendingWholeAllowanceLeavesZero(uint256 allowance) public {
        allowance = bound(allowance, 1, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowance);
        vm.prank(alice);
        token.transferFrom(deployer, bob, allowance);
        assertEq(token.allowance(deployer, alice), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
    }

    /// @dev One wei over the allowance is refused for any finite allowance: the boundary is tight.
    function testFuzz_transferFromOneWeiOverAllowanceReverts(uint256 allowance) public {
        allowance = bound(allowance, 0, SUPPLY - 1);
        vm.prank(deployer);
        token.approve(alice, allowance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowance, allowance + 1)
        );
        vm.prank(alice);
        token.transferFrom(deployer, bob, allowance + 1);
        assertEq(token.allowance(deployer, alice), allowance);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Allowance is checked before balance: with allowance below balance the allowance error
    ///      is reported, and with allowance above balance the balance error is reported.
    function test_transferFromReportsTheBindingLimit() public {
        _fund(alice, 10e18);
        vm.prank(alice);
        token.approve(bob, 5e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 5e18, 6e18));
        vm.prank(bob);
        token.transferFrom(alice, carol, 6e18);

        vm.prank(alice);
        token.approve(bob, 20e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e18, 11e18));
        vm.prank(bob);
        token.transferFrom(alice, carol, 11e18);
        assertEq(token.allowance(alice, bob), 20e18, "a failed transferFrom must not spend allowance");
    }

    function test_revertWhen_transferFromToZeroAddress() public {
        vm.prank(deployer);
        token.approve(alice, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transferFrom(deployer, address(0), 1e18);
        assertEq(token.allowance(deployer, alice), 1e18);
    }

    /// @dev transferFrom with the zero address as owner is refused before any balance is touched.
    ///      With zero value the allowance comparison passes and the allowance rewrite rejects the
    ///      zero owner as an invalid approver; with a positive value the allowance check rejects it.
    function test_revertWhen_transferFromZeroAddressOwner() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(alice);
        token.transferFrom(address(0), bob, 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(address(0), bob, 1);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromZeroValueWithoutApprovalSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Spending a finite allowance emits only Transfer, not Approval (OpenZeppelin v5
    ///      semantics). Pinned so an upgrade that changes the event surface is noticed.
    function test_transferFromEmitsOnlyTransfer() public {
        vm.prank(deployer);
        token.approve(alice, 10e18);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 4e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(deployer))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(bob))));
        assertEq(abi.decode(logs[0].data, (uint256)), 4e18);
    }

    // ---------------------------------------------------------------------------------------
    // Unknown call surface
    // ---------------------------------------------------------------------------------------

    /// @dev Any selector outside the ERC-20 mutators, with any arguments, from the deployer or a
    ///      stranger, leaves supply, balances and allowances untouched. Whether the call reverts is
    ///      not asserted (view selectors succeed); what matters is that nothing moves.
    function testFuzz_unknownSelectorChangesNothing(bytes4 selector, bytes memory args, bool fromDeployer) public {
        vm.assume(
            selector != IERC20.transfer.selector && selector != IERC20.approve.selector
                && selector != IERC20.transferFrom.selector
        );
        _fund(alice, 100e18);
        vm.prank(deployer);
        token.approve(bob, 50e18);

        address caller = fromDeployer ? deployer : address(0xBAD);
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        ok;

        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY - 100e18);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(0xBAD)), 0);
        assertEq(token.allowance(deployer, bob), 50e18);
        assertEq(token.allowance(deployer, address(0xBAD)), 0);
    }

    /// @dev The ERC-20 extension helpers OpenZeppelin dropped in v5 are absent, so no caller can
    ///      change an allowance by delta rather than by overwrite.
    function test_increaseDecreaseAllowanceDoNotExist() public {
        vm.prank(deployer);
        token.approve(alice, 10e18);
        vm.prank(deployer);
        (bool incOk,) = address(token).call(abi.encodeWithSignature("increaseAllowance(address,uint256)", alice, 1));
        vm.prank(deployer);
        (bool decOk,) = address(token).call(abi.encodeWithSignature("decreaseAllowance(address,uint256)", alice, 1));
        assertFalse(incOk);
        assertFalse(decOk);
        assertEq(token.allowance(deployer, alice), 10e18);
    }

    /// @dev Plain ETH with any value and any calldata is refused: there is no receive or fallback.
    function testFuzz_ethIsAlwaysRefused(uint96 value, bytes memory data) public {
        vm.deal(alice, value);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: value}(data);
        if (value > 0) assertFalse(ok);
        assertEq(address(token).balance, 0);
        assertEq(alice.balance, value);
    }
}
