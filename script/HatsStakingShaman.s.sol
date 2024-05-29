// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Script, console2 } from "forge-std/Script.sol";
import { HatsStakingShaman } from "../src/HatsStakingShaman.sol";
import {
  HatsModuleFactory, deployModuleFactory, deployModuleInstance
} from "lib/hats-module/src/utils/DeployFunctions.sol";

contract DeployImplementation is Script {
  HatsStakingShaman public implementation;
  bytes32 public SALT = keccak256("lets add some salt to this meal");

  // default values
  string public version = "0.1.0"; // increment with each deploy
  bool private verbose = true;

  /// @notice Override default values, if desired
  function prepare(string memory _version, bool _verbose) public {
    version = _version;
    verbose = _verbose;
  }

  function run() public {
    uint256 privKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.rememberKey(privKey);
    vm.startBroadcast(deployer);

    implementation = new HatsStakingShaman{ salt: SALT }(version);

    vm.stopBroadcast();

    if (verbose) {
      console2.log("HatsStakingShaman:", address(implementation));
    }
  }

  // forge script script/HatsStakingShaman.s.sol:DeployImplementation -f ethereum --broadcast --verify
}
