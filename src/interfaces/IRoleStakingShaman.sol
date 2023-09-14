// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { IBaal } from "baal/interfaces/IBaal.sol";
import { IBaalToken } from "baal/interfaces/IBaalToken.sol";

interface IRoleStakingShaman {
  /*//////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a staking requirement is set for a role
   * @param hat The role for which the staking requirement has been set
   * @param minStake The new staking requirement
   */
  event MinStakeSet(uint256 hat, uint112 minStake);

  /**
   * @notice Emitted when member's stake for a given hat is slashed
   * @param member The member whose stake has been slashed
   * @param hat The role for which their stake has been slashed
   * @param sharesBurned The amount of shares slashed
   * @param lootBurned The amount of loot slashed
   */
  event Slashed(address member, uint256 hat, uint112 sharesBurned, uint112 lootBurned);

  /**
   * @notice Emitted when a member stakes on a role
   * @param member The member who staked
   * @param hat The role they staked on
   * @param amount The amount of shares staked
   */
  event Staked(address member, uint256 hat, uint112 amount);

  /**
   * @notice Emitted when a member begins or resets the process of unstaking shares from a role
   * @param member The member doing the unstaking
   * @param hat The role from which they are unstaking
   * @param amount The amount of shares being unstaked
   */
  event UnstakeBegun(address member, uint256 hat, uint112 amount);

  /**
   * @notice Emitted when a the process of unstaking a member's shares from a role has been completed
   * @param member The member doing the unstaking
   * @param hat The role from which they are unstaking
   * @param amount The amount of shares being unstaked
   */
  event UnstakeCompleted(address member, uint256 hat, uint112 amount);

  /*//////////////////////////////////////////////////////////////
                            DATA MODELS
  //////////////////////////////////////////////////////////////*/

  /**
   * @dev Packed into a single storage slot
   * @param stakedAmount The amount of shares currently staked by the member for the role
   * @param unstakingAmount The amount of shares currently in the process of unstaking by the member for the role
   * @param canUnstakeAfter The timestamp after which the member can complete withdrawal of their untaked shares
   */
  struct Stake {
    uint112 stakedAmount;
    uint112 unstakingAmount;
    // FIXME this math is not right; need to increase to 64 bits for overflow safety & use uint96 for the above values
    uint32 canUnstakeAfter; // won't overflow until 2106, ie 2**32 / 60 / 60 / 24 / 365 = 136 years after epoch
  }

  /*//////////////////////////////////////////////////////////////
                          PUBLIC CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @notice The address of the Baal contract for which this contract is registered as a shaman
  function BAAL() external pure returns (IBaal);

  /// @notice Wearer(s) of this hat can set standing for a member for a given role
  function JUDGE_HAT() external pure returns (uint256);

  /// @notice Wearer(s) of this hat can create, register, and deregister roles for staking requirements
  function ROLE_MANAGER_HAT() external pure returns (uint256);

  /// @notice The address of the {BAAL} shares token
  function SHARES_TOKEN() external view returns (IBaalToken);

  /// @notice The address of the {BAAL} loot token
  function LOOT_TOKEN() external view returns (IBaalToken);

  /*//////////////////////////////////////////////////////////////
                          STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice The minimum amount of tokens that must be staked in order to be eligible for a role
  /// @dev Roles with minStake == 0 are considered invalid with respect to this contract
  function minStakes(uint256 hat) external view returns (uint112 minStake);

  /**
   * @notice Gets the amount of shares staked by a member for a given role
   * @param hat The role to get the staked amount for
   * @param member The member to get the staked amount for
   * @return stakedAmount The amount of shares currently staked by the member for the role
   * @return unstakingAmount The amount of shares currently in the process of unstaking by the member for the role
   * @return canUnstakeAfter The timestamp after which the member can complete withdrawal of their untaked shares
   */
  function roleStakes(uint256 hat, address member)
    external
    view
    returns (uint112 stakedAmount, uint112 unstakingAmount, uint32 canUnstakeAfter);

  /// @notice The amount of time, in seconds, that must elapse from the start of an unstaking process until it is
  /// completed
  function cooldownBuffer() external view returns (uint32);

  /*//////////////////////////////////////////////////////////////
                          HATTER FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Creates a new role as a direct child of {hatId} and adds a `_minStake` staking requirement for it
   * @param _details The details of the new subrole
   * @param _maxSupply The max supply of the new subrole
   * @param _eligibility The address of the new subrole's eligibility module
   *       - Typically, this should be set to the address of this instance of HatsRoleStakingShaman so that the hat
   *         eligibility is tied to the staking requirement. It's also acceptable to set it to another eligibility
   *         module, as long as that module's criteria includes the staking requirement.
   *       - If non-empty, this will replace the hat's existing eligibility module.
   * @param _toggle The address of the new subrole's toggle module
   * @param _mutable Whether the new subrole is mutable
   * @param _imageURI The image URI of the new subrole
   * @param _minStake The staking requirement for the new subrole
   * @return _hat The hatId of the new subrole
   */
  function createRole(
    string memory _details,
    uint32 _maxSupply,
    address _eligibility,
    address _toggle,
    bool _mutable,
    string memory _imageURI,
    uint112 _minStake
  ) external returns (uint256 _hat);

  /**
   * @notice Creates a new role as a lower-level descendent of {hatId} — ie as a direct child of `_admin` — and
   * adds a `_minStake` staking requirement for it
   * @param _admin The hatId of the new role's admin
   * @param _details The details of the new role
   * @param _maxSupply The max supply of the new role
   * @param _eligibility The address of the new role's eligibility module
   *       - Typically, this should be set to the address of this instance of HatsRoleStakingShaman so that the hat
   *         eligibility is tied to the staking requirement. It's also acceptable to set it to another eligibility
   *         module, as long as that module's criteria includes the staking requirement.
   *       - If non-empty, this will replace the hat's existing eligibility module.
   * @param _toggle The address of the new role's toggle module
   * @param _mutable Whether the new role is mutable
   * @param _imageURI The image URI of the new role
   * @param _minStake The staking requirement for the new role
   * @return _hat The hatId of the new role
   */
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

  /**
   * @notice Registers an existing role by adding a staking requirement
   * @param _hat The role to register
   * @param _minStake The staking requirement for the role
   * @param _eligibility The address of the role's eligibility module.
   *       - Typically, this should be set to the address of this instance of HatsRoleStakingShaman so that the hat
   *         eligibility is tied to the staking requirement. It's also acceptable to set it to another eligibility
   *         module, as long as that module's criteria includes the staking requirement.
   *       - If non-empty, this will replace the hat's existing eligibility module.
   */
  function registerRole(uint256 _hat, uint112 _minStake, address _eligibility) external;

  /**
   * @notice Deregisters a role by removing the staking requirement.
   * @param _hat The role to deregister
   */
  function deregisterRole(uint256 _hat) external;

  /**
   * @notice Sets the staking requirement for a role, defined by a hatId
   * @param _hat The role to set the staking requirement for
   * @param _minStake The new staking requirement
   */
  function setMinStake(uint256 _hat, uint112 _minStake) external;

  /*//////////////////////////////////////////////////////////////
                          ELIGIBILIY FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Sets the standing of a member for a role, defined by a hatId, only callable by a wearer of the {JUDGE_HAT}
   * @param _hat The hat to set standing for
   * @param _member The member to set standing for
   * @param _standing The standing to set
   */
  function setStanding(uint256 _hat, address _member, bool _standing) external;

  /*//////////////////////////////////////////////////////////////
                          STAKING FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Stake on a role without claiming it. Useful when the caller has not yet met the other eligibility criteria,
   * such as when staking triggers second eligibility evaluation processes.
   * @param _hat The role to stake on
   * @param _amount The amount of shares to stake, in uint112 ERC20 decimals
   */
  function stakeOnRole(uint256 _hat, uint112 _amount) external;

  /**
   * @notice Claim a role for which the caller has already staked. Useful when the caller staked prior to meeting the
   * other eligibility criteria.
   * @param _hat The hat to claim
   */
  function claimRole(uint256 _hat) external;

  /**
   * @notice Stake on and claim a role in a single transaction. Useful when the caller has already met the other
   * eligibility criteria.
   * @param _hat The role to stake on and claim
   * @param _amount The amount of shares to stake, in uint112 ERC20 decimals
   */
  function stakeAndClaimRole(uint256 _hat, uint112 _amount) external;

  /**
   * @notice Begins the process of unstaking shares from a role, defined by a hatId
   * @param _hat The role to unstake from
   * @param _amount The amount of shares to unstake, in uint112 ERC20 decimals
   */
  function beginUnstakeFromRole(uint256 _hat, uint112 _amount) external;

  /**
   * @notice Cancels an unstaking process for a role and starts a new one with a new value and new cooldown period.
   *  Useful when something outside of this contract (eg a direct baal or other shaman slash) changed the caller's
   * staked shares in the Staking Proxy, leading to failed sufficient stake checks. In such a scenario, the caller could
   * reduce their unstaking `_amount` to a value for which they have sufficient stake.
   * If the `_member` is in bad standing, this function will slash their stake.
   * @param _hat The role to unstake from
   * @param _amount The amount of shares to unstake, in uint112 ERC20 decimals
   */
  function resetUnstakeFromRole(uint256 _hat, uint112 _amount) external;

  /**
   * @notice Completes the process of unstaking shares from a role, defined by a hatId. If the `_member` is in bad
   * standing, this function will slash their stake.
   * @param _hat The role to unstake from
   * @param _member The member to unstake for
   */
  function completeUnstakeFromRole(uint256 _hat, address _member) external;

  /**
   * @notice Unstake all remaining shares from a role that has been unregistered from this contract registry. This
   * special case is not subject to a cooldown period, since the stake is no longer an eligibility criterion for the
   * role.
   * If some of the shares staked in the caller's staking proxy have been burned (eg by another shaman), all
   * remaining shares are unstaked and the caller's internal staking balance is set to zero.
   * @dev Nonetheless, a staker in bad standing is still slashed by this function.
   */
  function unstakeFromDeregisteredRole(uint256 _hat) external;

  /**
   * @notice Slashes a member's stake for a role, if they are in bad standing
   * @param _member The member to slash
   * @param _hat The role to slash for
   */
  function slash(address _member, uint256 _hat) external;

  /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The total staked by a given member, as measured by the share balance of their staking proxy
   * @param _member The member to get the staked shares for
   * @return totalStaked The amount of shares staked in the member's staking proxy, in uint112 ERC20 decimals
   */
  function memberStakes(address _member) external view returns (uint112 totalStaked);

  /**
   * @notice Derives the unstaking cooldown period as the sum of the {BAAL}'s voting and grace periods, and the
   * `cooldownBuffer`. This should give the {BAAL} enough time to place a misbehaving member in bad standing for a role
   * before they can complete their unstake.
   */
  function cooldownPeriod() external view returns (uint32);
}
