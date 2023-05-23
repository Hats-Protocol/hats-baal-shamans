// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import { Script, console2 } from "forge-std/Script.sol";
import { HatsOnboardingShaman } from "../src/HatsOnboardingShaman.sol";

contract Deploy is Script {
  HatsOnboardingShaman public shaman;
  bytes32 public SALT = keccak256("lets add some salt to this meal");

  // default values
  bool private verbose = true;

  /// @notice Override default values, if desired
  function prepare(bool _verbose) public {
    verbose = _verbose;
  }

  function run() public {
    uint256 privKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.rememberKey(privKey);
    vm.startBroadcast(deployer);

    shaman = new HatsOnboardingShaman{ salt: SALT}();

    vm.stopBroadcast();

    if (verbose) {
      console2.log("HatsOnboardingShaman:", address(shaman));
    }
  }
}

// forge script script/HatsOnboardingShaman.s.sol -f ethereum --broadcast --verify
