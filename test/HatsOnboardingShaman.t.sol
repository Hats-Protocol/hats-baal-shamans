// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import { Test, console2 } from "forge-std/Test.sol";
import { HatsOnboardingShaman } from "../src/HatsOnboardingShaman.sol";
import { Deploy } from "../script/Counter.s.sol";

contract CounterTest is Deploy, Test {
  // variables inhereted from Deploy script
  // HatsOnboardingShaman public shaman;

  uint256 public fork;
  uint256 public BLOCK_NUMBER;

  function setUp() public virtual {
    // create and activate a fork, at BLOCK_NUMBER
    // fork = vm.createSelectFork(vm.rpcUrl("mainnet"), BLOCK_NUMBER);

    // deploy via the script
    Deploy.prepare(false); // set to true to log deployment addresses
    Deploy.run();
  }
}
