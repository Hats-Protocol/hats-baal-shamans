// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { console2 } from "forge-std/Test.sol"; // remove before deploy
import { HatsModule, IHats } from "../lib/hats-module/src/HatsModule.sol";
import { IRoleStakingShaman } from "./interfaces/IRoleStakingShaman.sol";
import { IHatsEligibility } from "../lib/hats-module/lib/hats-protocol/src/Interfaces/IHatsEligibility.sol";
import { MultiClaimsHatter } from "../lib/multi-claims-hatter/src/MultiClaimsHatter.sol";
import { IBaal } from "../lib/baal/contracts/interfaces/IBaal.sol";
import { IBaalToken } from "../lib/baal/contracts/interfaces/IBaalToken.sol";
import { LibClone } from "../lib/solady/src/utils/LibClone.sol";
import { LibHatId } from "./LibHatId.sol";
import { StakingProxy } from "./StakingProxy.sol";

/**
 * @title Hats Staking Shaman
 * @notice This contract manages staking and unstaking of DAO members' shares for Hats Protocol-powered roles.
 * @dev This contract assumes that the Baal (along with its other approved shamans) is trusted and will not wontonly
 * burn members' shares, whether staked or not staked.
 * @author Haberdasher Labs
 * @author @spengrah
 * @dev This contract inherits from the HatsModule contract, and is meant to be deployed as a clone from the
 * HatsModuleFactory. To function properly, this contract must wear the {hatId} hat.
 */
contract HatsStakingShaman is IRoleStakingShaman, HatsModule, IHatsEligibility {
  /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when attempting to register, adjust, or deregister a role that is not mutable
  error InvalidMinStake();
  /// @notice Thrown when attempting to unstake from a registered role without a cooldown period
  error RoleStillRegistered();
  /// @notice Thrown when attempting to unstake from a role before the cooldown period has ended
  error CooldownNotEnded();
  /// @notice Thrown when attempting to claim or unstake from a role without sufficient stake
  error InsufficientStake();
  /// @notice Thrown when attempting to slash a member who is not in bad standing
  error NotInBadStanding();
  /// @notice Thrown when attempting to set standing for a member from an account not wearing the judge hat
  error NotJudge();
  /// @notice Thrown when attempting to change a role is not mutable
  error HatImmutable();
  /// @notice Thrown when attempting to set a role's properties without being an admin of that hat
  error NotAdmin();
  /// @notice Thrown when attempting to stake when this contract is not set as a Manager Shaman on the {BAAL}
  error NotShaman();

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
   * --------------------------------------------------------------------+
   * CLONE IMMUTABLE "STORAGE"                                           |
   * --------------------------------------------------------------------+
   * Offset | Constant             | Type    | Length | Source Contract  |
   * --------------------------------------------------------------------|
   * 0      | IMPLEMENTATION       | address | 20     | HatsModule       |
   * 20     | HATS                 | address | 20     | HatsModule       |
   * 40     | hatId                | uint256 | 32     | HatsModule       |
   * 72     | BAAL                 | address | 20     | this             |
   * 92     | STAKING_PROXY_IMPL   | address | 20     | this             |
   * --------------------------------------------------------------------+
   */

  /// @inheritdoc IRoleStakingShaman
  function BAAL() public pure returns (IBaal) {
    return IBaal(_getArgAddress(72));
  }

  /// @inheritdoc IRoleStakingShaman
  function STAKING_PROXY_IMPL() public pure returns (address) {
    return _getArgAddress(92);
  }

  /// @inheritdoc IRoleStakingShaman
  IBaalToken public SHARES_TOKEN;

  /*//////////////////////////////////////////////////////////////
                          MUTABLE STATE
  //////////////////////////////////////////////////////////////*/

  uint112 public minStake;

  /// @inheritdoc IRoleStakingShaman
  uint32 public cooldownBuffer;

  uint256 public judge;

  /// @inheritdoc IRoleStakingShaman
  mapping(address member => Stake stake) public stakes;

  /// @dev Internal tracker for member standing by hat, exposed publicly via {getWearerStatus}.
  /// Default is good standing (true).
  mapping(address member => bool badStanding) internal badStandings;

  /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  constructor(string memory _version) HatsModule(_version) { }

  /*//////////////////////////////////////////////////////////////
                          INITIALIZER
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc HatsModule
  function _setUp(bytes calldata _initData) internal override {
    SHARES_TOKEN = IBaalToken(BAAL().sharesToken());

    (cooldownBuffer, judge, minStake) = abi.decode(_initData, (uint32, uint256, uint112));

    _setJudge(judge);
    _setMinStake(minStake);
  }

  /*//////////////////////////////////////////////////////////////
                            PUBLIC ADMIN LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IRoleStakingShaman
  function setMinStake(uint112 _minStake) external onlyAdmin hatIsMutable {
    _setMinStake(_minStake);
  }

  function setJudge(uint256 _judge) external onlyAdmin hatIsMutable {
    _setJudge(_judge);
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL ADMIN LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @dev Internal function to set the staking requirement for a role, defined by a hatId
   * @param _minStake The new staking requirement
   */
  function _setMinStake(uint112 _minStake) internal {
    minStake = _minStake;

    emit MinStakeSet(_minStake);
  }

  function _setJudge(uint256 _judge) internal {
    judge = _judge;

    emit JudgeSet(_judge);
  }

  /*//////////////////////////////////////////////////////////////
                        ELIGIBILITY LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IHatsEligibility
  function getWearerStatus(address _member, uint256 /*_hatId*/ )
    external
    view
    override
    returns (bool eligible, bool standing)
  {
    // standing is the inverse of badStandings
    standing = !badStandings[_member];
    // eligible if member has sufficienet stake and is in good standing
    eligible = standing && _hasSufficientStake(_member);
  }

  /// @inheritdoc IRoleStakingShaman
  function setStanding(address _member, bool _standing) external onlyJudge {
    // standing is the inverse of badStandings
    badStandings[_member] = !_standing;
  }

  /**
   * @dev Checks if _member has sufficient stake for _hat
   * @param _member The member to check stake for
   * return Whether _member has sufficient stake for _hat
   */
  function _hasSufficientStake(address _member) internal view returns (bool) {
    // eligible if member stake for the hat being >= minStake
    return stakes[_member].stakedAmount >= minStake;
  }

  /*//////////////////////////////////////////////////////////////
                        PUBLIC STAKING LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IRoleStakingShaman
  function stake(uint112 _amount, address _delegate) external {
    _stake(msg.sender, _amount, _delegate);
  }

  /// @inheritdoc IRoleStakingShaman
  function claim(MultiClaimsHatter _claimsHatter) external {
    _claim(msg.sender, _claimsHatter);
  }

  /// @inheritdoc IRoleStakingShaman
  function stakeAndClaim(uint112 _amount, address _delegate, MultiClaimsHatter _claimsHatter) external {
    _stake(msg.sender, _amount, _delegate);
    _claim(msg.sender, _claimsHatter);
  }

  /// @inheritdoc IRoleStakingShaman
  function beginUnstake(uint112 _amount) external {
    // if caller is in bad standing, slash them and return
    if (!HATS().isInGoodStanding(msg.sender, hatId())) {
      _slashStake(msg.sender);
      return;
    }

    /**
     * @dev caller must have sufficient stake for _hat, both in internal roleStake accounting as well as their actual
     * shares in their Staking Proxy. The latter value may be too low if the shares were burned directly by the Baal or
     * another shaman.
     */
    Stake storage s = stakes[msg.sender];
    if (s.stakedAmount < _amount || SHARES_TOKEN.balanceOf(_calculateStakingProxyAddress(msg.sender)) < _amount) {
      revert InsufficientStake();
    }
    // caller must not be in cooldown period for _hat
    if (s.unstakingAmount > 0) revert CooldownNotEnded();

    // otherwise, proceed with the unstake, moving their stake for _hat to the cooldown queue
    s.unstakingAmount = _amount;
    unchecked {
      /// @dev Safe until 2106
      s.canUnstakeAfter = uint32(block.timestamp) + cooldownPeriod();
      /// @dev Safe since stake is sufficient
      s.stakedAmount -= _amount;
    }

    // log the unstake initiation
    emit UnstakeBegun(msg.sender, _amount);
  }

  /// @inheritdoc IRoleStakingShaman
  function resetUnstake(uint112 _newUnstakingAmount) external {
    // if caller is in bad standing, slash them and return
    if (!HATS().isInGoodStanding(msg.sender, hatId())) {
      _slashStake(msg.sender);
      return;
    }

    /**
     * @dev caller must have at least _amount stake for _hat, both in internal roleStake accounting (sum of staked and
     * unstaking) as well as their actual shares in their Staking Proxy.
     */
    Stake storage s = stakes[msg.sender];
    uint112 oldUnstakingAmount = s.unstakingAmount;
    uint256 allStaked = s.stakedAmount + oldUnstakingAmount;
    if (
      allStaked < _newUnstakingAmount
        || SHARES_TOKEN.balanceOf(_calculateStakingProxyAddress(msg.sender)) < _newUnstakingAmount
    ) {
      revert InsufficientStake();
    }

    unchecked {
      if (oldUnstakingAmount > _newUnstakingAmount) {
        // if the new unstaking amount is less than the old one, we need to increase the stakedAmount
        /// @dev Should not overflow given the condition
        s.stakedAmount += oldUnstakingAmount - _newUnstakingAmount;
      } else {
        // if the new unstaking amount is greater than the old one, we need to decrease the stakedAmount
        /// @dev Should not underflow given the condition
        s.stakedAmount -= _newUnstakingAmount - oldUnstakingAmount;
      }
      // update the unstaking amount to the new value
      s.unstakingAmount = _newUnstakingAmount;

      /// @dev Should not overflow until 2106
      s.canUnstakeAfter = uint32(block.timestamp) + cooldownPeriod();
    }

    // log the unstake initiation
    emit UnstakeBegun(msg.sender, _newUnstakingAmount);
  }

  /// @inheritdoc IRoleStakingShaman
  function completeUnstake(address _member) external {
    // // if _member is in bad standing, slash them and return
    if (!HATS().isInGoodStanding(_member, hatId())) {
      _slashStake(_member);
      return;
    }

    Stake storage s = stakes[_member];
    // cooldown period must be over
    if (s.canUnstakeAfter > block.timestamp) revert CooldownNotEnded();
    // caller must have sufficient total stake and sufficient actual shares in their staking proxy
    uint112 amount = s.unstakingAmount;
    address proxy = _calculateStakingProxyAddress(_member);

    if (SHARES_TOKEN.balanceOf(proxy) < amount) revert InsufficientStake();

    // remove their stake from the cooldown queue
    s.unstakingAmount = 0;
    s.canUnstakeAfter = 0;

    // transfer their amount of shares from the _member's staking proxy to _member
    /// @dev will revert if insufficient balance in proxy, which could happen if they got burned directly by another
    /// shaman or the Baal itself
    _transferShares(proxy, _member, amount);

    // log the unstake
    emit UnstakeCompleted(_member, amount);
  }

  /// @inheritdoc IRoleStakingShaman
  function unstakeFromDeregisteredRole() external {
    if (minStake > 0 && HATS().getHatEligibilityModule(hatId()) == address(this)) revert RoleStillRegistered();

    // if caller is in bad standing, slash them and return
    if (!HATS().isInGoodStanding(msg.sender, hatId())) {
      console2.log("slash");
      _slashStake(msg.sender);
      return;
    }

    // get the remaining staked balance from their proxy
    (uint256 proxyBalance, address proxy) = getStakedSharesAndProxy(msg.sender);
    // get their current stake for _hat
    Stake storage s = stakes[msg.sender];
    uint112 allStaked = s.stakedAmount + s.unstakingAmount;

    // Amount to unstake is the lesser of their allStaked and their proxy balance. This ensures that they can't use this
    // to withdraw their shares staked to other roles
    uint112 amount = allStaked < proxyBalance ? allStaked : uint112(proxyBalance);

    // clear their staked amount, and also clear any cooldown
    s.stakedAmount = 0;
    s.unstakingAmount = 0;
    s.canUnstakeAfter = 0;

    // transfer their amount to unstake from the msg.sender's staking proxy to msg.sender
    if (amount > 0) _transferShares(proxy, msg.sender, amount);

    // log the unstake
    emit UnstakeCompleted(msg.sender, amount);
  }

  /// @inheritdoc IRoleStakingShaman
  function slash(address _member) external {
    // member must be in bad standing for _hat
    if (HATS().isInGoodStanding(_member, hatId())) revert NotInBadStanding();

    // slash their stake
    _slashStake(_member);
  }

  /// @inheritdoc IRoleStakingShaman
  function delegate(address _newDelegate) external {
    address proxy = _calculateStakingProxyAddress(msg.sender);
    StakingProxy(proxy).delegate(_newDelegate);
  }

  /*//////////////////////////////////////////////////////////////
                      INTERNAL STAKING LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @dev Internal function for staking on a role. Called by {stakeOnRole} and {stakeAndClaimRole}. Staked shares are
   * held in a staking proxy contract unique to `_member`.
   * @param _member The member staking on the role
   * @param _amount The amount of shares to stake, in uint112 ERC20 decimals
   * @param _delegate The address to delegate the staked share votes to
   */
  function _stake(address _member, uint112 _amount, address _delegate) internal {
    // don't attempt staking staking unless this contract is set as a manager shaman on the Baal
    if (!isManagerShaman()) revert NotShaman();

    // add _amount to _member's stake
    stakes[_member].stakedAmount += _amount;

    // calculate _member's staking proxy address
    address proxy = _calculateStakingProxyAddress(_member);

    // transfer _amount of shares from _member to their staking proxy
    _transferShares(_member, proxy, _amount);

    // delegate shares from proxy back to the _delegate of _member's choosing, deploy a staking proxy for _member if
    // they don't yet have one
    if (proxy.code.length == 0) _deployStakingProxy(_member);
    StakingProxy(proxy).delegate(_delegate);

    // log the stake
    emit Staked(_member, _amount);
  }

  /**
   * @dev Internal function to claim a hat. This call will revert if...
   *       - the hat is not "claimable-for" in the MultiClaimsHatter, or
   *       - caller is currently wearing the hat, or
   *       - caller is not eligible for this hat according to this contract, i.e. insufficient stake, or
   *       - caller is not eligible for this hat according to or other chained eligibility modules
   * @param _claimer The address claiming the role
   * @param _claimsHatter The claimsHatter to use for claiming
   */
  function _claim(address _claimer, MultiClaimsHatter _claimsHatter) internal {
    _claimsHatter.claimHatFor(hatId(), _claimer);

    /// @dev We don't log claiming since its already logged by the ERC1155.TransferSingle event emitted by HATS.mintHat
  }

  /**
   * @dev Internal function to slash a member's stake for a role, if they are in bad standing.
   * @param _member The member to slash
   */
  function _slashStake(address _member) internal {
    // set _member's stake for _hat to 0
    Stake storage s = stakes[_member];
    uint112 amount;

    if (s.unstakingAmount > 0) {
      // _member is in cooldown, so we need to account for their unstakingAmount
      unchecked {
        // Should not overflow since these are two components of a staked amount total, which did not previously
        // overflow
        amount = s.stakedAmount + s.unstakingAmount;
      }
      // and clear their cooldown
      s.unstakingAmount = 0;
      s.canUnstakeAfter = 0;
    } else {
      // _member is not in cooldown, so we just care about their stakedAmount
      amount = s.stakedAmount;
    }
    // in either case, we clear their stakedAmount
    s.stakedAmount = 0;

    // make sure the actual amount to burn is not greater than the member's proxy balance
    // (which could happen if the baal or another shaman burned some directly)
    uint112 proxyBalance = memberStakes(_member);
    if (amount > proxyBalance) amount = proxyBalance;

    // burn the shares
    _burnShares(_member, amount);

    // log the slash
    emit Slashed(_member, amount);
  }

  /*//////////////////////////////////////////////////////////////
                          PUBLIC GETTERS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IRoleStakingShaman
  function cooldownPeriod() public view returns (uint32) {
    unchecked {
      /// @dev Reasonable Baal voting + grace period will not exceed 2**32 seconds (~136 years)
      return BAAL().votingPeriod() + BAAL().gracePeriod() + cooldownBuffer;
    }
  }

  /// @inheritdoc IRoleStakingShaman
  function getStakedSharesAndProxy(address _member) public view returns (uint112 amount, address stakingProxy) {
    stakingProxy = _calculateStakingProxyAddress(_member);
    amount = uint112(SHARES_TOKEN.balanceOf(stakingProxy));
  }

  /// @inheritdoc IRoleStakingShaman
  function memberStakes(address _member) public view returns (uint112 totalStaked) {
    return uint112(SHARES_TOKEN.balanceOf(_calculateStakingProxyAddress(_member)));
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL SHAMAN LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @dev Internal function to transfer shares from one address to another. This contract must be approved as a shaman
   * on the Baal for this action to succeed.
   * @param _from The address to transfer from
   * @param _to The address to transfer to
   * @param _amount The amount of shares to transfer, in uint112 ERC20 decimals
   */
  function _transferShares(address _from, address _to, uint112 _amount) internal {
    uint256[] memory amounts = new uint256[](1);
    address[] memory members = new address[](1);
    amounts[0] = uint256(_amount);

    // burn from _from
    members[0] = _from;
    BAAL().burnShares(members, amounts);

    // mint to _to
    members[0] = _to;
    BAAL().mintShares(members, amounts);
  }

  /**
   * @dev Internal function to burn shares for a member. This contract must be approved as a shaman on the Baal for this
   * action to succeed.
   * @param _from The address to burn from. Shares are burned from this address's staking proxy.
   * @param _amount The amount of shares to burn, in uint112 ERC20 decimals
   */
  function _burnShares(address _from, uint112 _amount) internal {
    uint256[] memory amounts = new uint256[](1);
    address[] memory members = new address[](1);
    amounts[0] = uint256(_amount);
    members[0] = _calculateStakingProxyAddress(_from);
    BAAL().burnShares(members, amounts);
  }

  /*//////////////////////////////////////////////////////////////
                  INTERNAL SHARE STAKING PROXY LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @dev Predict the address of a member's staking proxy, which is deterministically generated from their address, the
   * address of the shares token, and the address of this contract
   */
  function _calculateStakingProxyAddress(address _member) internal view returns (address) {
    bytes memory args = _encodeArgs(_member);
    return LibClone.predictDeterministicAddress(STAKING_PROXY_IMPL(), args, _generateSalt(args), address(this));
  }

  /**
   * @dev Deploy a deterministic proxy for `_member`, with immutable args of `address(this)`, `address(SHARES_TOKEN)`,
   * and `_member`
   */
  function _deployStakingProxy(address _member) internal returns (address) {
    bytes memory args = _encodeArgs(_member);

    return LibClone.cloneDeterministic(STAKING_PROXY_IMPL(), args, _generateSalt(args));
  }

  /**
   * @dev Encode packed the args for the staking proxy: `address(this)`, `address(SHARES_TOKEN)`, and `_member`
   */
  function _encodeArgs(address _member) internal view returns (bytes memory) {
    return abi.encodePacked(address(this), address(SHARES_TOKEN), _member);
  }

  /**
   * @dev Generate a salt for the share staking proxy, as the keccak256 hash of its args
   */
  function _generateSalt(bytes memory _args) internal pure returns (bytes32) {
    return keccak256(_args);
  }

  /*//////////////////////////////////////////////////////////////
                    ADDITIONAL HELPER FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Check if this contract is set as a manager shaman on the BAAL
   */
  function isManagerShaman() public view returns (bool) {
    return BAAL().isManager(address(this));
  }

  /*//////////////////////////////////////////////////////////////
                            MODIFIERS
  //////////////////////////////////////////////////////////////*/

  modifier onlyAdmin() {
    if (!HATS().isAdminOfHat(msg.sender, hatId())) revert NotAdmin();
    _;
  }

  modifier onlyJudge() {
    if (!HATS().isWearerOfHat(msg.sender, judge)) revert NotJudge();
    _;
  }

  modifier hatIsMutable() {
    bool mutable_;
    (,,,,,,, mutable_,) = HATS().viewHat(hatId());
    if (!mutable_) revert HatImmutable();
    _;
  }
}
