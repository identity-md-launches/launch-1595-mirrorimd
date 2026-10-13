// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MirrorIMD (MIRROR)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 MIRROR (18 decimals) is minted
///         once, in the constructor, to the deployer. There is no owner, no further minting, no
///         pause, no blocklist, and no fee or burn on transfer: every transfer moves exactly the
///         amount requested.
/// @dev The deployer is `msg.sender` of the creation transaction. On an IdentityMD launch that is
///      the ProjectFactory, which then distributes the supply (swarm share, pool seed, remainder)
///      according to the launch manifest. The constructor takes no arguments and calls no other
///      contract, so it deploys identically on an empty chain.
contract MirrorToken is ERC20 {
    /// @notice Token name, as returned by `name()`.
    string public constant TOKEN_NAME = "MirrorIMD";

    /// @notice Token symbol, as returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "MIRROR";

    /// @notice Whole-token supply before applying decimals.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 1_000_000_000;

    /// @notice The fixed total supply in minor units: 1,000,000,000 * 10^18.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** 18;

    /// @notice Emitted once, when the constructor mints the whole supply.
    /// @param recipient The deployer that received the whole supply.
    /// @param amount The amount minted, equal to `TOTAL_SUPPLY`.
    event SupplyMinted(address indexed recipient, uint256 amount);

    /// @notice Mints the entire fixed supply to the deployer.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
        emit SupplyMinted(msg.sender, TOTAL_SUPPLY);
    }
}
