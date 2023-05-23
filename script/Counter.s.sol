// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import { Script, console2 } from "forge-std/Script.sol";
import { Counter } from "../src/Counter.sol";

contract Deploy is Script {
  Counter public counter;
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

    counter = new Counter{ salt: SALT}();

    vm.stopBroadcast();

    if (verbose) {
      console2.log("Counter:", address(counter));
    }
  }
}

// forge script script/Deploy.s.sol -f ethereum --broadcast --verify
