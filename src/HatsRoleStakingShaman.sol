// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// import { console2 } from "forge-std/Test.sol"; // remove before deploy
import { HatsModule, IHats } from "hats-module/HatsModule.sol";
import { IRoleStakingShaman } from "src/interfaces/IRoleStakingShaman.sol";
import { IHatsEligibility } from "hats-protocol/Interfaces/IHatsEligibility.sol";
import { IBaal } from "baal/interfaces/IBaal.sol";
import { IBaalToken } from "baal/interfaces/IBaalToken.sol";
import { LibClone } from "solady/utils/LibClone.sol";
import { LibHatId } from "src/LibHatId.sol";
import { StakingProxy } from "src/StakingProxy.sol";

/**
 * @title Hats Role Staking Shaman
 * @notice This contract manages staking and unstaking of DAO members' shares for Hats Protocol-powered roles.
 * @author Haberdasher Labs
 * @author @spengrah
 * @dev This contract inherits from the HatsModule contract, and is meant to be deployed as a clone from the
 * HatsModuleFactory. To function properly, this contract must wear the {hatId} hat.
 */
contract HatsRoleStakingShaman is IRoleStakingShaman, HatsModule, IHatsEligibility {
  /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a role is already registered
  error RoleAlreadyRegistered();
  /// @notice Thrown when a role is not registered or not within the branch of {hatId}
  error InvalidRole();
  /// @notice Thrown when attempting to register, adjust, or deregister a role that is not mutable
  error InvalidMinStake();
  /// @notice Thrown when attempting to unstake from a registered role without a cooldown period
  error RoleStillRegistered();
  /// @notice Thrown when attempting to claim a role for which the claimer is not explicitly eligible
  error NotEligible();
  /// @notice Thrown when attempting to unstake from a role before the cooldown period has ended
  error CooldownNotEnded();
  /// @notice Thrown when attempting to claim or unstake from a role without sufficient stake
  error InsufficientStake();
  /// @notice Thrown when attempting to slash a member who is not in bad standing
  error NotInBadStanding();
  /// @notice Thrown when attempting to create, register, adjust, or deregister a role from an account not wearing the
  /// {ROLE_MANAGER_HAT}
  error NotRoleManager();
  /// @notice Thrown when attempting to set standing for a member from an account not wearing the {JUDGE_HAT}
  error NotJudge();
  /// @notice Thrown when attempting to change a role is not mutable
  error HatImmutable();

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
   * 112    | ROLE_MANAGER_HAT     | uint256 | 32     | this             |
   * 144    | JUDGE_HAT            | uint256 | 32     | this             |
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
  function ROLE_MANAGER_HAT() public pure returns (uint256) {
    return _getArgUint256(112);
  }

  /// @inheritdoc IRoleStakingShaman
  function JUDGE_HAT() public pure returns (uint256) {
    return _getArgUint256(144);
  }

  /// @inheritdoc IRoleStakingShaman
  IBaalToken public SHARES_TOKEN;

  /*//////////////////////////////////////////////////////////////
                          MUTABLE STATE
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IRoleStakingShaman
  mapping(uint256 hat => uint112 minStake) public minStakes;

  /// @inheritdoc IRoleStakingShaman
  mapping(uint256 hat => mapping(address member => Stake stake)) public roleStakes;

  /// @inheritdoc IRoleStakingShaman
  uint32 public cooldownBuffer;

  /// @dev Internal tracker for member standing by hat, exposed publicly via {getWearerStatus}.
  /// Default is good standing (true).
  mapping(uint256 hat => mapping(address member => bool badStanding)) internal badStandings;

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

    cooldownBuffer = abi.decode(_initData, (uint32));
  }

  /*//////////////////////////////////////////////////////////////
                        PUBLIC HATTER LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IRoleStakingShaman
  function createRole(
    string memory _details,
    uint32 _maxSupply,
    address _eligibility,
    address _toggle,
    bool _mutable,
    string memory _imageURI,
    uint112 _minStake
  ) external onlyRoleManager returns (uint256 _hat) {
    // create the new role
    _hat = _createRole(hatId(), _details, _maxSupply, _eligibility, _toggle, _mutable, _imageURI, _minStake);
  }

  /// @inheritdoc IRoleStakingShaman
  function createSubRole(
    uint256 _admin,
    string memory _details,
    uint32 _maxSupply,
    address _eligibility,
    address _toggle,
    bool _mutable,
    string memory _imageURI,
    uint112 _minStake
  ) external onlyRoleManager returns (uint256 _hat) {
    // create the new role
    _hat = _createRole(_admin, _details, _maxSupply, _eligibility, _toggle, _mutable, _imageURI, _minStake);
  }

  /// @inheritdoc IRoleStakingShaman
  function registerRole(uint256 _hat, uint112 _minStake, address _eligibility)
    external
    onlyRoleManager
    hatIsMutable(_hat)
  {
    // ensure the role is in hatId()'s branch
    if (!_inBranch(_hat)) revert InvalidRole();
    // ensure the role hasn't already been added or created
    if (minStakes[_hat] != 0) revert RoleAlreadyRegistered();

    // change the hat's eligibility module, if set
    if (_eligibility > address(0)) HATS().changeHatEligibility(_hat, _eligibility);

    _setMinStake(_hat, _minStake);
  }

  /// @inheritdoc IRoleStakingShaman
  function deregisterRole(uint256 _hat) external onlyRoleManager hatIsMutable(_hat) {
    _setMinStake(_hat, 0);
  }

  /// @inheritdoc IRoleStakingShaman
  function setMinStake(uint256 _hat, uint112 _minStake) external validRole(_hat) onlyRoleManager hatIsMutable(_hat) {
    _setMinStake(_hat, _minStake);
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL HATTER LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @dev Internal function to create a new role as a direct child or as a lower-level descendent of {hatId}
   * @param _admin The hatId of the new role's admin
   * @param _details The details of the new role
   * @param _maxSupply The max supply of the new role
   * @param _eligibility The address of the new role's eligibility module
   * @param _toggle The address of the new role's toggle module
   * @param _mutable Whether the new role is mutable
   * @param _imageURI The image URI of the new role
   * @param _minStake The staking requirement for the new role
   * @return _hat The hatId of the new role
   */
  function _createRole(
    uint256 _admin,
    string memory _details,
    uint32 _maxSupply,
    address _eligibility,
    address _toggle,
    bool _mutable,
    string memory _imageURI,
    uint112 _minStake
  ) internal returns (uint256 _hat) {
    // create the new hat
    _hat = HATS().createHat(_admin, _details, _maxSupply, _eligibility, _toggle, _mutable, _imageURI);
    // register the role by setting its minStake
    _setMinStake(_hat, _minStake);
  }

  /**
   * @dev Internal function to set the staking requirement for a role, defined by a hatId
   * @param _hat The role to set the staking requirement for
   * @param _minStake The new staking requirement
   */
  function _setMinStake(uint256 _hat, uint112 _minStake) internal {
    minStakes[_hat] = _minStake;

    emit MinStakeSet(_hat, _minStake);
  }

  /**
   * @notice Internal helper function to check if a given `_hat` is a descendent — in the branch of — {hatId}
   */
  function _inBranch(uint256 _hat) internal pure returns (bool) {
    // {hatId} is our branch root
    uint256 branchRoot = hatId();
    // get the hat level of our branch
    uint32 branchRootLevel = LibHatId.getLocalHatLevel(branchRoot);
    // get the admin of _hat at that level
    uint256 hatAdmin = LibHatId.getAdminAtLocalLevel(_hat, branchRootLevel);
    // _hat is in our branch if its admin *is* our branch id
    return hatAdmin == branchRoot;
  }

  /*//////////////////////////////////////////////////////////////
                        ELIGIBILITY LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IHatsEligibility
  function getWearerStatus(address _member, uint256 _hatId)
    external
    view
    override
    returns (bool eligible, bool standing)
  {
    // standing is the inverse of badStandings
    standing = !badStandings[_hatId][_member];
    // eligible if member stake for the hat being >= minStake, unless standing is false
    eligible = standing ? _hasSufficientStake(_hatId, _member) : false;
  }

  /// @inheritdoc IRoleStakingShaman
  function setStanding(uint256 _hat, address _member, bool _standing) external validRole(_hat) onlyJudge {
    // standing is the inverse of badStandings
    badStandings[_hat][_member] = !_standing;
  }

  /**
   * @dev Checks if _member has sufficient stake for _hat
   * @param _hat The hat to check stake for
   * @param _member The member to check stake for
   * return Whether _member has sufficient stake for _hat
   */
  function _hasSufficientStake(uint256 _hat, address _member) internal view returns (bool) {
    // eligible if member stake for the hat being >= minStake
    return roleStakes[_hat][_member].stakedAmount >= minStakes[_hat];
  }

  /**
   * @notice Checks if _wearer is explicitly eligible to wear the hat.
   * @dev Explicit eligibility can only come from a mechanistic eligitibility module, ie a contract that implements
   * IHatsEligibility
   * @param _hat The hat to check eligibility for
   * @param _eligibility The address of the hat's eligibility module
   * @param _wearer The address of the would-be wearer to check for eligibility
   */
  function _isExplicitlyEligible(uint256 _hat, address _eligibility, address _wearer)
    internal
    view
    returns (bool eligible)
  {
    // get _wearer's eligibility status from the eligibility module
    bool standing;
    (bool success, bytes memory returndata) =
      _eligibility.staticcall(abi.encodeWithSignature("getWearerStatus(address,uint256)", _wearer, _hat));

    /* 
    * if function call succeeds with data of length == 64, then we know the contract exists 
    * and has the getWearerStatus function (which returns two words).
    * But — since function selectors don't include return types — we still can't assume that the return data is two
    booleans, 
    * so we treat it as a uint so it will always safely decode without throwing.
    */
    if (success && returndata.length == 64) {
      // check the returndata manually
      (uint256 firstWord, uint256 secondWord) = abi.decode(returndata, (uint256, uint256));
      // returndata is valid
      if (firstWord < 2 && secondWord < 2) {
        standing = (secondWord == 1) ? true : false;
        // never eligible if in bad standing
        eligible = (standing && firstWord == 1) ? true : false;
      }
      // returndata is invalid
      else {
        // false since _wearer is not explicitly eligible
        eligible = false;
      }
    } else {
      // false since _wearer is not explicitly eligible
      eligible = false;
    }
  }

  /*//////////////////////////////////////////////////////////////
                        PUBLIC STAKING LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IRoleStakingShaman
  function stakeOnRole(uint256 _hat, uint112 _amount, address _delegate) external validRole(_hat) {
    _stakeOnRole(msg.sender, _hat, _amount, _delegate);
  }

  /// @inheritdoc IRoleStakingShaman
  function claimRole(uint256 _hat) external validRole(_hat) {
    _claimRole(msg.sender, _hat);
  }

  /// @inheritdoc IRoleStakingShaman
  function stakeAndClaimRole(uint256 _hat, uint112 _amount, address _delegate) external validRole(_hat) {
    _stakeOnRole(msg.sender, _hat, _amount, _delegate);
    _claimRole(msg.sender, _hat);
  }

  /// @inheritdoc IRoleStakingShaman
  function beginUnstakeFromRole(uint256 _hat, uint112 _amount) external {
    // if caller is in bad standing, slash them and return
    if (!HATS().isInGoodStanding(msg.sender, _hat)) {
      _slashStake(msg.sender, _hat);
      return;
    }

    /**
     * @dev caller must have sufficient stake for _hat, both in internal roleStake accounting as well as their actual
     * shares in their Staking Proxy. The latter value may be too low if the shares were burned directly by the Baal or
     * another shaman.
     */
    Stake storage stake = roleStakes[_hat][msg.sender];
    if (stake.stakedAmount < _amount || SHARES_TOKEN.balanceOf(_calculateStakingProxyAddress(msg.sender)) < _amount) {
      revert InsufficientStake();
    }
    // caller must not be in cooldown period for _hat
    if (stake.unstakingAmount > 0) revert CooldownNotEnded();

    // otherwise, proceed with the unstake, moving their stake for _hat to the cooldown queue
    stake.unstakingAmount = _amount;
    unchecked {
      /// @dev Safe until 2106
      stake.canUnstakeAfter = uint32(block.timestamp) + cooldownPeriod();
      /// @dev Safe since stake is sufficient
      stake.stakedAmount -= _amount;
    }

    // log the unstake initiation
    emit UnstakeBegun(msg.sender, _hat, _amount);
  }

  /// @inheritdoc IRoleStakingShaman
  function resetUnstakeFromRole(uint256 _hat, uint112 _amount) external {
    // if caller is in bad standing, slash them and return
    if (!HATS().isInGoodStanding(msg.sender, _hat)) {
      _slashStake(msg.sender, _hat);
      return;
    }

    /**
     * @dev caller must have at least _amount stake for _hat, both in internal roleStake accounting (sum of staked and
     * unstaking) as well as their actual shares in their Staking Proxy.
     */
    Stake storage stake = roleStakes[_hat][msg.sender];
    uint112 oldUnstakingAmount = stake.unstakingAmount;
    uint256 allStaked = stake.stakedAmount + oldUnstakingAmount;
    if (allStaked < _amount || SHARES_TOKEN.balanceOf(_calculateStakingProxyAddress(msg.sender)) < _amount) {
      revert InsufficientStake();
    }

    unchecked {
      if (oldUnstakingAmount > _amount) {
        // if the new unstaking amount is less than the old one, we need to increase the stakedAmount
        /// @dev Should not overflow given the condition
        stake.stakedAmount += oldUnstakingAmount - _amount;
      } else {
        // if the new unstaking amount is greater than the old one, we need to decrease the stakedAmount
        /// @dev Should not underflow given the condition
        stake.stakedAmount -= _amount - oldUnstakingAmount;
      }
      // update the unstaking amount to the new value
      stake.unstakingAmount = _amount;

      /// @dev Should not overflow until 2106
      stake.canUnstakeAfter = uint32(block.timestamp) + cooldownPeriod();
    }

    // log the unstake initiation
    emit UnstakeBegun(msg.sender, _hat, _amount);
  }

  /// @inheritdoc IRoleStakingShaman
  function completeUnstakeFromRole(uint256 _hat, address _member) external {
    // // if _member is in bad standing, slash them and return
    if (!HATS().isInGoodStanding(_member, _hat)) {
      _slashStake(_member, _hat);
      return;
    }

    Stake storage stake = roleStakes[_hat][_member];
    // cooldown period must be over
    if (stake.canUnstakeAfter > block.timestamp) revert CooldownNotEnded();
    // caller must have sufficient total stake and sufficient actual shares in their staking proxy
    uint112 amount = stake.unstakingAmount;
    address proxy = _calculateStakingProxyAddress(_member);

    if (SHARES_TOKEN.balanceOf(proxy) < amount) revert InsufficientStake();

    // remove their stake from the cooldown queue
    stake.unstakingAmount = 0;
    stake.canUnstakeAfter = 0;

    // transfer their amount of shares from the _member's staking proxy to _member
    /// @dev will revert if insufficient balance in proxy, which could happen if they got burned directly by another
    /// shaman or the Baal itself
    _transferShares(proxy, _member, amount);

    // log the unstake
    emit UnstakeCompleted(_member, _hat, amount);
  }

  /// @inheritdoc IRoleStakingShaman
  function unstakeFromDeregisteredRole(uint256 _hat) external {
    if (minStakes[_hat] > 0) revert RoleStillRegistered();

    // if caller is in bad standing, slash them and return
    if (!HATS().isInGoodStanding(msg.sender, _hat)) {
      _slashStake(msg.sender, _hat);
      return;
    }

    // get their remaining staked balance
    (uint256 proxyBalance, address proxy) = getStakedSharesAndProxy(msg.sender);
    uint112 amount = uint112(proxyBalance);

    // clear their staked amount, and also clear any cooldown
    Stake storage stake = roleStakes[_hat][msg.sender];
    stake.stakedAmount = 0;
    stake.unstakingAmount = 0;
    stake.canUnstakeAfter = 0;

    // transfer their amount of shares from the msg.sender's staking proxy to msg.sender
    if (amount > 0) _transferShares(proxy, msg.sender, amount);

    // log the unstake
    emit UnstakeCompleted(msg.sender, _hat, amount);
  }

  /// @inheritdoc IRoleStakingShaman
  function slash(address _member, uint256 _hat) external validRole(_hat) {
    // member must be in bad standing for _hat
    if (HATS().isInGoodStanding(_member, _hat)) revert NotInBadStanding();

    // slash their stake
    _slashStake(_member, _hat);
  }

  /*//////////////////////////////////////////////////////////////
                      INTERNAL STAKING LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @dev Internal function for staking on a role. Called by {stakeOnRole} and {stakeAndClaimRole}. Staked shares are
   * held in a staking proxy contract unique to `_member`.
   * @param _member The member staking on the role
   * @param _hat The role to stake on
   * @param _amount The amount of shares to stake, in uint112 ERC20 decimals
   * @param _delegate The address to delegate the staked share votes to
   */
  function _stakeOnRole(address _member, uint256 _hat, uint112 _amount, address _delegate) internal {
    // add _amount to _member's stake for _hat
    roleStakes[_hat][_member].stakedAmount += _amount;

    // calculate _member's staking proxy address
    address proxy = _calculateStakingProxyAddress(_member);

    // transfer _amount of shares from _member to their staking proxy
    _transferShares(_member, proxy, _amount);

    // delegate shares from proxy back to the _delegate of _member's choosing, deploy a staking proxy for _member if
    // they don't yet have one
    if (proxy.code.length == 0) _deployStakingProxy(_member);
    StakingProxy(proxy).delegate(_delegate);

    // log the stake
    emit Staked(_member, _hat, _amount);
  }

  /**
   * @dev Claimer must be explicitly eligible for _hat in order to wear it. If _hat's eligibility module
   * is this contract, the only criterion is sufficient stake. If it's another contract, we need to check for explicit
   * eligibility.
   * NOTE: Developers of eligibility modules for stakeable roles should include a check to this contract as one of
   * their eligibility criteria
   * @param _claimer The address claiming the role
   * @param _hat The role to claim
   */
  function _claimRole(address _claimer, uint256 _hat) internal {
    // get _hat's eligibility module
    address eligibility = HATS().getHatEligibilityModule(_hat);

    if (eligibility == address(this)) {
      // check this contract for eligibility
      if (!_hasSufficientStake(_hat, _claimer)) revert InsufficientStake();
    } else {
      // check the _hat's eligibility module for explicity eligibility
      if (!_isExplicitlyEligible(_hat, eligibility, _claimer)) revert NotEligible();
    }

    // mint hat to _claimer
    HATS().mintHat(_hat, _claimer);

    /// @dev We don't log claiming since its already logged by the ERC1155.TransferSingle event emitted by HATS.mintHat
  }

  /**
   * @dev Internal function to slash a member's stake for a role, if they are in bad standing. Called by {slash} and
   * {_checkSlash}.
   * @param _member The member to slash
   * @param _hat The role to slash for
   */
  function _slashStake(address _member, uint256 _hat) internal {
    // set _member's stake for _hat to 0
    Stake storage stake = roleStakes[_hat][_member];
    uint112 amount;

    if (stake.unstakingAmount > 0) {
      // _member is in cooldown, so we need to account for their unstakingAmount
      unchecked {
        // Should not overflow since these are two components of a staked amount total, which did not previously
        // overflow
        amount = stake.stakedAmount + stake.unstakingAmount;
      }
      // and clear their cooldown
      stake.unstakingAmount = 0;
      stake.canUnstakeAfter = 0;
    } else {
      // _member is not in cooldown, so we just care about their stakedAmount
      amount = stake.stakedAmount;
    }
    // in either case, we clear their stakedAmount
    stake.stakedAmount = 0;

    // make sure the actual amount to burn is not greater than the member's proxy balance
    // (which could happen if the baal or another shaman burned some directly)
    uint112 proxyBalance = memberStakes(_member);
    if (amount > proxyBalance) amount = proxyBalance;

    // burn the shares
    _burnShares(_member, amount);

    // burn their hat (it's already been dynamically revoked by the eligibility module, but now we fully burn it)
    HATS().checkHatWearerStatus(_hat, _member);

    // log the slash
    emit Slashed(_member, _hat, amount);
  }

  /**
   * @dev Internal function to check if a member is in bad standing for a role, and slash their stake if so. Called by
   * {beginUnstakeFromRole} and {completeUnstakeFromRole}.
   * @param _member The member to check and potentially slash
   * @param _hat The role to check for
   */
  function _checkSlash(address _member, uint256 _hat) internal returns (bool _slashed) {
    // check if _member is in bad standing for _hat
    if (!HATS().isInGoodStanding(_member, _hat)) {
      _slashStake(_member, _hat);
      _slashed = true;
    }
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
                            MODIFIERS
  //////////////////////////////////////////////////////////////*/

  modifier onlyRoleManager() {
    if (!HATS().isWearerOfHat(msg.sender, ROLE_MANAGER_HAT())) revert NotRoleManager();
    _;
  }

  modifier onlyJudge() {
    if (!HATS().isWearerOfHat(msg.sender, JUDGE_HAT())) revert NotJudge();
    _;
  }

  modifier validRole(uint256 _hat) {
    if (minStakes[_hat] == 0) revert InvalidRole();
    _;
  }

  modifier hatIsMutable(uint256 _hat) {
    bool mutable_;
    (,,,,,,, mutable_,) = HATS().viewHat(_hat);
    if (!mutable_) revert HatImmutable();
    _;
  }
}
