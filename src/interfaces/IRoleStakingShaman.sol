// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { IBaal } from "baal/interfaces/IBaal.sol";
import { IBaalToken } from "baal/interfaces/IBaalToken.sol";

interface IRoleStakingShaman {
  /*//////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  event MinStakeSet(uint256 _hat, uint112 _minStake);
  event Slashed(address member, uint256 hat, uint112 amount);
  event Staked(address member, uint256 hat, uint112 amount);
  event UnstakeBegun(address member, uint256 hat, uint112 amount);
  event UnstakeCompleted(address member, uint256 hat, uint112 amount);

  /*//////////////////////////////////////////////////////////////
                            DATA MODELS
  //////////////////////////////////////////////////////////////*/

  /**
   * @dev Packed into a single storage slot
   * @custom:member amount The amount of tokens staked
   */
  struct Stake {
    uint112 stakedAmount;
    uint112 unstakingAmount;
    uint32 canUnstakeAfter; // won't overflow until 2106, ie 2**32 / 60 / 60 / 24 / 365 = 136 years after epoch
  }

  /*//////////////////////////////////////////////////////////////
                          PUBLIC CONSTANTS
  //////////////////////////////////////////////////////////////*/

  function BAAL() external pure returns (IBaal);
  function JUDGE_HAT() external pure returns (uint256);
  function ROLE_MANAGER_HAT() external pure returns (uint256);
  function SHARES_TOKEN() external view returns (IBaalToken);
  function STAKING_PROXY_IMPL() external pure returns (address);

  /*//////////////////////////////////////////////////////////////
                          STATE VARIABLES
  //////////////////////////////////////////////////////////////*/
  function memberStakes(address member) external view returns (uint112 totalStaked);

  /// @notice The minimum amount of tokens that must be staked in order to be eligible for a role
  /// @dev Roles with minStake == 0 are considered invalid with respect to this contract
  function minStakes(uint256 hat) external view returns (uint112 minStake);
  function roleStakes(uint256 hat, address member)
    external
    view
    returns (uint112 stakedAmount, uint112 unstakingAmount, uint32 canUnstakeAfter);

  /*//////////////////////////////////////////////////////////////
                          HATTER FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function createRole(
    string memory _details,
    uint32 _maxSupply,
    address _eligibility,
    address _toggle,
    bool _mutable,
    string memory _imageURI,
    uint112 _minStake
  ) external returns (uint256 _hat);

  function createSubRole(
    uint256 _admin,
    string memory _details,
    uint32 _maxSupply,
    address _eligibility,
    address _toggle,
    bool _mutable,
    string memory _imageURI,
    uint112 _minStake
  ) external returns (uint256 _hat);

  function registerRole(uint256 _hat, uint112 _minStake, address _eligibility) external;
  function deregisterRole(uint256 _hat) external;
  function setMinStake(uint256 _hat, uint112 _minStake) external;

  /*//////////////////////////////////////////////////////////////
                          ELIGIBILIY FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function setStanding(uint256 _hat, address _member, bool _standing) external;

  /*//////////////////////////////////////////////////////////////
                          STAKING FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function stakeOnRole(uint256 _hat, uint112 _amount, address _delegate) external;
  function claimRole(uint256 _hat) external;
  function stakeAndClaimRole(uint256 _hat, uint112 _amount, address _delegate) external;
  function beginUnstakeFromRole(uint256 _hat, uint112 _amount) external;
  function completeUnstakeFromRole(uint256 _hat, address _member) external;
  function cooldownPeriod() external view returns (uint32);
  function slash(address _member, uint256 _hat) external;

  /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function getStakedSharesAndProxy(address _member) external view returns (uint112 amount, address stakingProxy);
  function cooldownBuffer() external view returns (uint32);
}