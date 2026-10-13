// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MirrorToken} from "../src/MirrorToken.sol";

/// @title Handler that drives MirrorToken with bounded inputs from a fixed set of actors.
/// @notice Every mutating ERC-20 entry point is exercised in random order. Inputs are bounded so
///         the success paths never revert (the suite runs with fail-on-revert), while the failure
///         paths are exercised inside try/catch and asserted to revert with the exact typed error
///         and to leave state untouched. Ghost variables mirror what the token should hold so the
///         invariants can compare the contract against an independent model.
contract MirrorTokenHandler is Test {
    MirrorToken public immutable token;
    address public immutable deployer;
    uint256 public immutable supply;

    address[] public actors;

    // Ghost model of the token's state.
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    mapping(address => uint256) public ghostReceived;
    mapping(address => uint256) public ghostSent;

    // Call accounting, so a reviewer can see the handler reached every path.
    uint256 public transfers;
    uint256 public approvals;
    uint256 public transferFroms;
    uint256 public infiniteTransferFroms;
    uint256 public rejectedOverBalance;
    uint256 public rejectedOverAllowance;
    uint256 public rejectedZeroReceiver;
    uint256 public rejectedZeroSpender;
    uint256 public strangerCalls;

    constructor(MirrorToken token_, address deployer_, address[] memory actors_) {
        token = token_;
        deployer = deployer_;
        supply = token_.totalSupply();
        actors = actors_;
        ghostBalance[deployer_] = supply;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    // -----------------------------------------------------------------------------------------
    // Success paths (bounded so they never revert)
    // -----------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");

        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender debited wrong amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver credited wrong amount");
        }

        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        transfers++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assertTrue(ok, "approve returned false");
        assertEq(token.allowance(owner, spender), amount, "approve did not overwrite allowance");

        ghostAllowance[owner][spender] = amount;
        approvals++;
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);

        uint256 allowed = token.allowance(owner, spender);
        uint256 cap = token.balanceOf(owner) < allowed ? token.balanceOf(owner) : allowed;
        amount = bound(amount, 0, cap);

        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        assertTrue(ok, "transferFrom returned false");

        if (owner == to) {
            assertEq(token.balanceOf(owner), ownerBefore, "self-transferFrom changed balance");
        } else {
            assertEq(token.balanceOf(owner), ownerBefore - amount, "owner debited wrong amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver credited wrong amount");
        }

        if (allowed == type(uint256).max) {
            assertEq(token.allowance(owner, spender), type(uint256).max, "infinite allowance was decremented");
            infiniteTransferFroms++;
        } else {
            assertEq(token.allowance(owner, spender), allowed - amount, "allowance spent wrong amount");
            ghostAllowance[owner][spender] = allowed - amount;
        }

        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        ghostSent[owner] += amount;
        ghostReceived[to] += amount;
        transferFroms++;
    }

    // -----------------------------------------------------------------------------------------
    // Failure paths (must revert with the typed error and change nothing)
    // -----------------------------------------------------------------------------------------

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 amount = balance + excess;

        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        try token.transfer(to, amount) {
            assertTrue(false, "transfer above balance succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount),
                "wrong error for transfer above balance"
            );
        }
        assertEq(token.balanceOf(from), balance, "failed transfer changed sender balance");
        assertEq(token.balanceOf(to), toBefore, "failed transfer changed receiver balance");
        rejectedOverBalance++;
    }

    function transferFromOverAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) {
            // Nothing exceeds an infinite allowance; make it finite first so the path is reachable.
            allowed = bound(excess, 0, token.balanceOf(owner));
            vm.prank(owner);
            token.approve(spender, allowed);
            ghostAllowance[owner][spender] = allowed;
        }
        excess = bound(excess, 1, type(uint256).max - allowed);
        uint256 amount = allowed + excess;

        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            assertTrue(false, "transferFrom above allowance succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount),
                "wrong error for transferFrom above allowance"
            );
        }
        assertEq(token.allowance(owner, spender), allowed, "failed transferFrom changed allowance");
        assertEq(token.balanceOf(owner), ownerBefore, "failed transferFrom changed owner balance");
        assertEq(token.balanceOf(to), toBefore, "failed transferFrom changed receiver balance");
        rejectedOverAllowance++;
    }

    function transferToZeroAddress(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 before = token.balanceOf(from);
        vm.prank(from);
        try token.transfer(address(0), amount) {
            assertTrue(false, "transfer to the zero address succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)),
                "wrong error for transfer to zero"
            );
        }
        assertEq(token.balanceOf(from), before, "failed transfer to zero changed balance");
        assertEq(token.balanceOf(address(0)), 0, "zero address holds tokens");
        rejectedZeroReceiver++;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        try token.approve(address(0), amount) {
            assertTrue(false, "approve of the zero spender succeeded");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)),
                "wrong error for approve of zero spender"
            );
        }
        assertEq(token.allowance(owner, address(0)), 0, "zero spender has an allowance");
        rejectedZeroSpender++;
    }

    /// @dev A caller who is not who the code assumed, calling a selector the token does not define
    ///      (including the usual privileged names), from either a stranger or the deployer. The
    ///      token must not reach any state the ghosts do not know about. Only the three ERC-20
    ///      mutators are excluded because the ghosts cannot model their effects from raw calldata.
    function strangerCall(uint256 callerSeed, uint256 selectorSeed, bytes32 rawSelector, bytes calldata args) external {
        string[16] memory names = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "seize(address)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)",
            "increaseAllowance(address,uint256)",
            "decreaseAllowance(address,uint256)"
        ];
        uint256 pick = bound(selectorSeed, 0, names.length);
        bytes4 selector = pick == names.length ? bytes4(rawSelector) : bytes4(keccak256(bytes(names[pick])));
        if (
            selector == IERC20.transfer.selector || selector == IERC20.approve.selector
                || selector == IERC20.transferFrom.selector
        ) {
            selector = bytes4(keccak256("mint(address,uint256)"));
        }

        address caller = bound(callerSeed, 0, 1) == 0 ? deployer : address(0xBAD);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        ok;
        assertEq(token.totalSupply(), supplyBefore, "an unknown selector changed the supply");
        strangerCalls++;
    }
}

/// @title Invariants of MirrorToken over random call sequences.
/// @dev fail-on-revert is on: the handler bounds every success-path input, so any revert that
///      escapes it is itself a finding, not noise.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MirrorTokenInvariantTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    MirrorToken internal token;
    MirrorTokenHandler internal handler;
    address internal deployer = makeAddr("deployer");
    address[] internal actors;

    function setUp() public virtual {
        vm.prank(deployer);
        token = new MirrorToken();

        actors.push(deployer);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("distributor"));
        actors.push(makeAddr("pool"));

        handler = new MirrorTokenHandler(token, deployer, actors);
        targetContract(address(handler));
    }

    /// @dev Fixed supply: no sequence of calls, from anyone, creates or destroys a unit.
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
    }

    /// @dev Conservation: every unit the token tracks is held by one of the actors, since the
    ///      handler only ever moves value between them. Nothing leaks to the zero address or to
    ///      the token itself.
    function invariant_sumOfActorBalancesEqualsSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, EXPECTED_SUPPLY, "actor balances do not sum to the supply");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(token)), 0, "the token holds its own tokens");
        assertEq(token.balanceOf(address(handler)), 0, "the handler holds tokens");
    }

    /// @dev Internal accounting equals external reality: every balance matches the ghost model
    ///      built from the amounts the handler asked the token to move.
    function invariant_balancesMatchGhostModel() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            assertEq(token.balanceOf(actors[i]), handler.ghostBalance(actors[i]), "balance drifted from ghost");
        }
    }

    /// @dev Every allowance equals what the last approve set, less exactly what transferFrom spent,
    ///      and an allowance of max is never decremented.
    function invariant_allowancesMatchGhostModel() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            for (uint256 j = 0; j < actors.length; j++) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.ghostAllowance(actors[i], actors[j]),
                    "allowance drifted from ghost"
                );
            }
        }
    }

    /// @dev Nobody holds more than they were sent: a non-deployer's balance is exactly what it
    ///      received minus what it sent, and the deployer's is the supply adjusted the same way.
    function invariant_nobodyHoldsMoreThanTheyReceived() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 opening = actor == deployer ? EXPECTED_SUPPLY : 0;
            assertEq(
                token.balanceOf(actor) + handler.ghostSent(actor),
                opening + handler.ghostReceived(actor),
                "balance is not opening + received - sent"
            );
            assertLe(token.balanceOf(actor), EXPECTED_SUPPLY, "a holder exceeds the supply");
        }
    }

    /// @dev Metadata is immutable: nothing in the call surface can rename or redenominate the token.
    function invariant_metadataNeverChanges() public view {
        assertEq(token.name(), "MirrorIMD");
        assertEq(token.symbol(), "MIRROR");
        assertEq(token.decimals(), 18);
        assertEq(address(token).balance, 0, "the token holds ETH");
    }
}

/// @title Open-mode invariants: the fuzzer calls the token directly, with any sender and any
///        arguments, and reverts are allowed. Only properties that hold for arbitrary holders
///        are asserted here; the handler suite above asserts the accounting ones.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
contract MirrorTokenOpenInvariantTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    MirrorToken internal token;
    address internal deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new MirrorToken();
        targetContract(address(token));
        targetSender(deployer);
        targetSender(makeAddr("alice"));
        targetSender(makeAddr("bob"));
        targetSender(address(0xBAD));
    }

    function invariant_openSupplyIsFixed() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function invariant_openDeployerNeverExceedsSupply() public view {
        assertLe(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function invariant_openZeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_openMetadataIsFixed() public view {
        assertEq(token.name(), "MirrorIMD");
        assertEq(token.symbol(), "MIRROR");
        assertEq(token.decimals(), 18);
    }
}
