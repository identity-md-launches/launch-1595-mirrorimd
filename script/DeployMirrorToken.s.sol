// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {MirrorToken} from "../src/MirrorToken.sol";

/// @title Deploy script for MirrorToken
/// @notice Reviewable reference deployment. On an IdentityMD launch the factory deploys the token
///         from its attested bytecode, so this script is for local or manual deployments only.
///         The token takes no constructor arguments, so there is nothing to configure: the account
///         that sends the creation transaction receives the whole supply.
contract DeployMirrorToken is Script {
    /// @notice Deploys the token. Tests call this directly; `run()` wraps it in a broadcast.
    /// @return token The deployed token.
    function deploy() public returns (MirrorToken token) {
        token = new MirrorToken();
    }

    /// @notice Broadcast entry point for `forge script`. Reads nothing from the environment
    ///         beyond the signer that `forge script` itself selects.
    function run() external returns (MirrorToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
