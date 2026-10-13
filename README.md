# MirrorIMD (MIRROR)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum mainnet.

| Property        | Value                                         |
| --------------- | --------------------------------------------- |
| Solidity name   | `MirrorToken` (`src/MirrorToken.sol`)         |
| `name()`        | `MirrorIMD`                                   |
| `symbol()`      | `MIRROR`                                      |
| `decimals()`    | 18                                            |
| `totalSupply()` | 1,000,000,000 MIRROR = `1000000000000000000000000000` minor units |
| Constructor     | no arguments; mints the whole supply to `msg.sender` |
| Compiler        | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"`, `cbor_metadata = false` |

## Behaviour

- The entire supply is minted exactly once, in the constructor, to the deployer (the `msg.sender`
  of the creation transaction). The constructor emits the standard `Transfer(0x0, deployer, supply)`
  plus a `SupplyMinted(deployer, supply)` event.
- There is no owner, no admin role, no `mint`, no `burn`, no pause, no blocklist, no fee and no
  burn on transfer. The supply can never grow, and every transfer moves exactly the amount asked.
- The contract is OpenZeppelin Contracts v5.0.2 `ERC20` with nothing added beyond the three
  public constants and the `SupplyMinted` event. The vendored library files live under
  `lib/openzeppelin-contracts/` as ordinary files (no git submodule).
- The constructor calls no other contract and needs no address to have code, so it deploys
  identically on an empty chain.
- No `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` appears in the runtime bytecode, there are no
  external library calls, and the contract cannot receive plain ETH.

## Launch assumptions

These come from the launch, not from this repository, and are listed so reviewers can check them.

- Chain: Ethereum mainnet (chain id 1). Pair: native ETH.
- The IdentityMD ProjectFactory sends the creation transaction and therefore receives the whole
  supply. It then forwards the swarm's 10% to the launch's MerkleDistributor, seeds the Uniswap v4
  pool with the requester's `poolBps` share and sends the remainder to `economics.remainderTo`.
  Because the token has no exemptions and no transfer rules, all of these flows arrive whole.
- Deployment parameters for the manifest step (which writes `launch.json`, not this repository):
  - `token.contract`: `MirrorToken`
  - `token.name`: `MirrorIMD`
  - `token.symbol`: `MIRROR`
  - `token.decimals`: `18`
  - `token.constructorArgs`: `[]`
  - `token.totalSupply`: `1000000000000000000000000000`
  - no application contracts (`contracts: []`)
- The pool opens at the launch's fee (12500 = 1.25%) and tick spacing 60, with the price derived
  by the deployer from `economics.initialMarketCapWei`. Nothing in this contract depends on those.

## After launch

Nothing. The token has no owner-settable configuration, so there is no setter to call and no
value the owner must supply. Holders interact with it only through the standard ERC-20 surface.

## Operational responsibilities

- **No privileged party exists.** Nobody can mint, pause, freeze, seize or upgrade. If a holder
  loses a key, nobody can recover the balance. Tokens sent to the zero address are refused by
  `transfer`, but tokens sent to any other wrong address are unrecoverable.
- **The deployer's custody is the only trust point.** Whoever sends the creation transaction holds
  100% of the supply at block one. On the IdentityMD launch that is the factory, which distributes
  it under the launch policy. In a manual deployment it is the broadcasting account.
- **Allowances follow ERC-20 semantics.** An allowance of `type(uint256).max` is treated as
  infinite and is not decremented. Users should approve only what they intend to spend.
- **Source verification** on the block explorer after the launch is the deployer's job
  (`forge verify-contract` with compiler 0.8.26, optimizer 200 runs, no metadata hash).

## Repository layout

```
foundry.toml                  solc 0.8.26, bytecode_hash none, ffi off, no fs permissions
remappings.txt                forge-std/ and @openzeppelin/contracts/
src/MirrorToken.sol           the token
script/DeployMirrorToken.s.sol   reference deploy script; deploy() is called directly by tests
test/MirrorToken.t.sol        27 tests (success, failure, fuzz, privileged-surface, bytecode scan)
lib/forge-std/                forge-std 1.9.7 (src only, vendored as files)
lib/openzeppelin-contracts/   OpenZeppelin Contracts 5.0.2 ERC20 subset (vendored as files)
```

## Building and testing

```
forge build
forge test
forge fmt --check
```

The tests read no environment variables and depend on no particular caller, so they pass in any
order and in parallel with an empty environment.

## Reference deployment (manual, outside the launch)

The launch deploys the token from its attested bytecode, so the script below is only for local
or manual deployments and is included for review. It reads nothing from the environment except the
signer `forge script` selects.

```
forge script script/DeployMirrorToken.s.sol:DeployMirrorToken --rpc-url <RPC> --broadcast
```

## Security notes

Checked against the eth-security checklist supplied with the task:

- Access control: no privileged functions exist.
- Reentrancy: no external calls are made by the token.
- Decimals: 18, fixed; the supply constant is computed from it.
- Return values: `transfer`, `transferFrom` and `approve` return `true` or revert with typed
  ERC-6093 errors.
- Input validation: zero-address receivers, senders and spenders are rejected by the library.
- Events: every balance and allowance change emits `Transfer` or `Approval`.
- No proxies, no delegatecall, no signatures, no oracles, no swaps are involved.
- Tooling run: `forge build`, `forge test` (including a 256-run fuzz), `forge fmt --check`.
  Slither and Mythril were not available in this environment and did not run.

Tests passing do not constitute a security audit. Independent adversarial review before release
remains the launch's responsibility.
