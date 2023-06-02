// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// import { console2 } from "forge-std/Test.sol"; // remove before deploy
import { Clone } from "hats-module/HatsModule.sol";
import { IBaalToken } from "baal/interfaces/IBaalToken.sol";

contract StakingProxy is Clone {
  /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
  //////////////////////////////////////////////////////////////*/

  error NotRoleStakingShaman();

  /*//////////////////////////////////////////////////////////////
                          PUBLIC CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /**
   * This contract is a clone with immutable args, which means that it is deployed with a set of
   * immutable storage variables (ie constants). Accessing these constants is cheaper than accessing
   * regular storage variables (such as those set on initialization of a typical EIP-1167 clone),
   * but requires a slightly different approach since they are read from calldata instead of storage.
   *
   * Below is a table of constants and their locations. The first three are inherited from HatsModule.
   *
   * For more, see here: https://github.com/Saw-mon-and-Natalie/clones-with-immutable-args
   *
   * ---------------------------------------------------------------------+
   * Offset | Constant            | Type    | Length | Source Contract    |
   * ---------------------------------------------------------------------|
   * 0      | ROLE_STAKING_SHAMAN | address | 20     | this               |
   * 20     | SHARES_TOKEN        | address | 20     | this               |
   * 40     | MEMBER              | address | 20     | this               |
   * ---------------------------------------------------------------------+
   */

  function ROLE_STAKING_SHAMAN() public pure returns (address) {
    return _getArgAddress(0);
  }

  function SHARES_TOKEN() public pure returns (IBaalToken) {
    return IBaalToken(_getArgAddress(20));
  }

  function MEMBER() public pure returns (address) {
    return _getArgAddress(40);
  }

  /*//////////////////////////////////////////////////////////////
                          DELEGATE LOGIC
  //////////////////////////////////////////////////////////////*/

  function delegate() external {
    if (msg.sender != ROLE_STAKING_SHAMAN()) revert NotRoleStakingShaman();

    SHARES_TOKEN().delegate(MEMBER());
  }
}
