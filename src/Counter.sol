// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

// import { console2 } from "forge-std/Test.sol"; // remove before deploy

contract Counter {
  uint256 public number;

  function setNumber(uint256 newNumber) public {
    number = newNumber;
  }

  function increment() public {
    number++;
  }
}
