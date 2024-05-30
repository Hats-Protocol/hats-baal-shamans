// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { IBaal } from "../../lib/baal/contracts/interfaces/IBaal.sol";
import { IBaalToken } from "../../lib/baal/contracts/interfaces/IBaalToken.sol";
import { MultiClaimsHatter } from "../../lib/multi-claims-hatter/src/MultiClaimsHatter.sol";

interface IHatsStakingShaman {
  /*//////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a staking requirement is set for a role
   * @param minStake The new staking requirement
   */
  event MinStakeSet(uint112 minStake);

  /**
   * @notice Emitted when member's stake for a given hat is slashed
   * @param member The member whose stake has been slashed
   * @param amount The amount of shares slashed
   */
  event Slashed(address member, uint112 amount);

  /**
   * @notice Emitted when a member stakes on a role
   * @param member The member who staked
   * @param amount The amount of shares staked
   */
  event Staked(address member, uint112 amount);

  /**
   * @notice Emitted when a member begins or resets the process of unstaking shares from a role
   * @param member The member doing the unstaking
   * @param amount The amount of shares being unstaked
   */
  event UnstakeBegun(address member, uint112 amount);

  /**
   * @notice Emitted when the process of unstaking a member's shares from a role has been completed
   * @param member The member doing the unstaking
   * @param amount The amount of shares being unstaked
   */
  event UnstakeCompleted(address member, uint112 amount);

  /**
   * @notice Emitted when a judge for a role is set
   * @param judge The new judge
   */
  event JudgeSet(uint256 judge);

  /*//////////////////////////////////////////////////////////////
                            DATA MODELS
  //////////////////////////////////////////////////////////////*/

  /**
   * @dev Packed into a single storage slot
   */
  struct Stake {
    uint112 stakedAmount;
    uint112 unstakingAmount;
    uint32 canUnstakeAfter; // won't overflow until 2106, ie 2**32 / 60 / 60 / 24 / 365 = 136 years after epoch
  }

  struct RoleConfig {
    uint112 minStake;
    address claimsHatter;
    uint256 judge;
  }

  /*//////////////////////////////////////////////////////////////
                          PUBLIC CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @notice The address of the Baal contract for which this contract is registered as a shaman
  function BAAL() external pure returns (IBaal);

  /// @notice The address of the {BAAL} shares token
  function SHARES_TOKEN() external view returns (IBaalToken);

  /// @notice The address of the implementation of the staking proxy contract
  function STAKING_PROXY_IMPL() external pure returns (address);

  /*//////////////////////////////////////////////////////////////
                          STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice The minimum amount of tokens that must be staked in order to be eligible
  function minStake() external view returns (uint112 minStake);

  /**
   * @notice Gets the amount of shares staked by a member for a given role
   * @param member The member to get the staked amount for
   * @return stakedAmount The amount of shares currently staked by the member for the role
   * @return unstakingAmount The amount of shares currently in the process of unstaking by the member for the role
   * @return canUnstakeAfter The timestamp after which the member can complete withdrawal of their untaked shares
   */
  function stakes(address member)
    external
    view
    returns (uint112 stakedAmount, uint112 unstakingAmount, uint32 canUnstakeAfter);

  /// @notice The amount of time, in seconds, that must elapse from the start of an unstaking process until it is
  /// completed
  function cooldownBuffer() external view returns (uint32);

  /// @notice The hat id of the judge, who can set the standing of a member
  function judge() external view returns (uint256);

  /*//////////////////////////////////////////////////////////////
                          HATTER FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Sets the staking requirement for a role, defined by a hatId
   * @param _minStake The new staking requirement
   */
  function setMinStake(uint112 _minStake) external;

  /*//////////////////////////////////////////////////////////////
                          ELIGIBILIY FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Sets the standing of a member for a role, defined by a hatId, only callable by a wearer of the {JUDGE_HAT}
   * @param _member The member to set standing for
   * @param _standing The standing to set
   */
  function setStanding(address _member, bool _standing) external;

  /*//////////////////////////////////////////////////////////////
                          STAKING FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Stake on a role without claiming it. Useful when the caller has not yet met the other eligibility criteria,
   * such as when staking triggers second eligibility evaluation processes.
   * @param _amount The amount of shares to stake, in uint112 ERC20 decimals
   * @param _delegate The address to delegate the staked share votes to
   */
  function stake(uint112 _amount, address _delegate) external;

  /**
   * @notice Claim a role for which the caller has already staked. Useful when the caller staked prior to meeting the
   * other eligibility criteria.
   * @param _claimsHatter The claims hatter to use to claim the role
   */
  function claim(MultiClaimsHatter _claimsHatter) external;

  /**
   * @notice Stake on and claim a role in a single transaction. Useful when the caller has already met the other
   * eligibility criteria.
   * @param _amount The amount of shares to stake, in uint112 ERC20 decimals
   * @param _delegate The address to delegate the staked share votes to
   * @param _claimsHatter The claims hatter to use to claim the role
   */
  function stakeAndClaim(uint112 _amount, address _delegate, MultiClaimsHatter _claimsHatter) external;

  /**
   * @notice Begins the process of unstaking shares from a role, defined by a hatId
   * @param _amount The amount of shares to unstake, in uint112 ERC20 decimals
   */
  function beginUnstake(uint112 _amount) external;

  /**
   * @notice Cancels an unstaking process for a role and starts a new one with a new value and new cooldown period.
   *  Useful when something outside of this contract (eg a direct baal or other shaman slash) changed the caller's
   * staked shares in the Staking Proxy, leading to failed sufficient stake checks. In such a scenario, the caller could
   * reduce their unstaking `_newUnstakingAmount` to a value for which they have sufficient stake.
   * If the `_member` is in bad standing, this function will slash their stake.
   * @param _newUnstakingAmount The amount of shares to unstake, in uint112 ERC20 decimals
   */
  function resetUnstake(uint112 _newUnstakingAmount) external;

  /**
   * @notice Completes the process of unstaking shares from a role, defined by a hatId. If the `_member` is in bad
   * standing, this function will slash their stake.
   * @param _member The member to unstake for
   */
  function completeUnstake(address _member) external;

  /**
   * @notice Unstake all remaining shares from a role that has been unregistered from this contract registry. This
   * special case is not subject to a cooldown period, since the stake is no longer an eligibility criterion for the
   * role.
   * If some of the shares staked in the caller's staking proxy have been burned (eg by another shaman), all
   * remaining shares are unstaked and the caller's internal staking balance is set to zero.
   * @dev Nonetheless, a staker in bad standing is still slashed by this function.
   */
  function unstakeFromDeregisteredRole() external;

  /**
   * @notice Slashes a member's stake for a role, if they are in bad standing
   * @param _member The member to slash
   */
  function slash(address _member) external;

  /**
   * @notice Delegates the caller's stake to a new address
   * @param _newDelegate The new delegate to set
   */
  function delegate(address _newDelegate) external;

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

  /**
   * @notice Gets the staking proxy address and shares staked therein for a `_member`.
   * @dev The staking proxy address is deterministically generated from `_member`'s address and the address of this, so
   * for gas efficiency we derive it here rather than store it.
   */
  function getStakedSharesAndProxy(address _member) external view returns (uint112 amount, address stakingProxy);
}
