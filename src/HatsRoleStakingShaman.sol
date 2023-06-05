// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

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
 * HatsModuleFactory.
 */
contract HatsRoleStakingShaman is IRoleStakingShaman, HatsModule, IHatsEligibility {
  /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
  //////////////////////////////////////////////////////////////*/

  error RoleAlreadyAdded();
  error InvalidRole();
  error NotEligible();
  error CooldownNotEnded();
  error InsufficientStake();
  error NotInBadStanding();
  error NotRoleManager();
  error NotJudge();
  error NotHatAdmin();
  error HatImmutable();

  /*//////////////////////////////////////////////////////////////
                        INTERNAL CONSTANTS
  //////////////////////////////////////////////////////////////*/

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
   * 92     | OWNER_HAT            | uint256 | 32     | this             |
   * 124    | STAKING_PROXY_IMPL   | address | 20     | this             |
   * 144    | ROLE_MANAGER_HAT     | uint256 | 32     | this             |
   * 164    | JUDGE_HAT            | uint256 | 32     | this             |
   * --------------------------------------------------------------------+
   */

  /// @inheritdoc IRoleStakingShaman
  function BAAL() public pure returns (IBaal) {
    return IBaal(_getArgAddress(72));
  }

  /// @inheritdoc IRoleStakingShaman
  function OWNER_HAT() public pure returns (uint256) {
    return _getArgUint256(92);
  }

  /// @inheritdoc IRoleStakingShaman
  function STAKING_PROXY_IMPL() public pure returns (address) {
    return _getArgAddress(124);
  }

  /// @inheritdoc IRoleStakingShaman
  function ROLE_MANAGER_HAT() public pure returns (uint256) {
    return _getArgUint256(144);
  }

  /// @inheritdoc IRoleStakingShaman
  function JUDGE_HAT() public pure returns (uint256) {
    return _getArgUint256(164);
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
  mapping(uint256 hat => mapping(address member => bool badStanding)) public badStandings;

  /// @inheritdoc IRoleStakingShaman
  mapping(address member => uint256 totalStaked) public memberStakes;

  /// @inheritdoc IRoleStakingShaman
  uint32 public cooldownBuffer;

  /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  constructor(string memory _version) HatsModule(_version) { }

  /*//////////////////////////////////////////////////////////////
                          INITIALIZER
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc HatsModule
  function setUp(bytes calldata _initData) public override initializer {
    SHARES_TOKEN = IBaalToken(BAAL().sharesToken());
    // LOOT_TOKEN = IBaalToken(BAAL().lootToken());

    uint32 cooldownBuffer_ = abi.decode(_initData, (uint32));
    // TODO do we need these intermediate variables, or can we just assign directly to storage?
    cooldownBuffer = cooldownBuffer_;
  }

  /*//////////////////////////////////////////////////////////////
                          HATTER LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Creates a new role as a direct child of {hatId} and adds a `_minStake` staking requirement for it
   */
  function createRole(
    string memory _details,
    uint32 _maxSupply,
    address _eligibility,
    address _toggle,
    bool _mutable,
    string memory _imageURI,
    uint112 _minStake
  ) external onlyRoleManager {
    // create the new role
    _createRole(hatId(), _details, _maxSupply, _eligibility, _toggle, _mutable, _imageURI, _minStake);
  }

  /**
   * @notice Creates a new role as a lower-level descendent of {hatId} and adds a `_minStake` staking requirement for it
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
  ) external onlyRoleManager {
    // create the new role
    _createRole(_admin, _details, _maxSupply, _eligibility, _toggle, _mutable, _imageURI, _minStake);
  }

  /**
   * @notice Adds a staking requirement to an existing role, defined by a hatId
   */
  function addRole(uint256 _hat, uint112 _minStake) external onlyRoleManager hatIsMutable {
    // ensure the role is in hatId()'s branch
    if (!_inBranch(_hat)) revert InvalidRole();
    // ensure the role hasn't already been added or created
    if (minStakes[_hat] != 0) revert RoleAlreadyAdded();

    _setMinStake(_hat, _minStake);
  }

  /**
   * @notice Removes the staking requirement from a role, defined by a hatId
   */
  function removeRole(uint256 _hat) external validRole(_hat) onlyRoleManager hatIsMutable {
    _setMinStake(_hat, 0);
  }

  /**
   * @notice Sets the staking requirement for a role, defined by a hatId
   */
  function setMinStake(uint256 _hat, uint112 _minStake) external validRole(_hat) onlyRoleManager hatIsMutable {
    _setMinStake(_hat, _minStake);
  }

  function _createRole(
    uint256 _admin,
    string memory _details,
    uint32 _maxSupply,
    address _eligibility,
    address _toggle,
    bool _mutable,
    string memory _imageURI,
    uint112 _minStake
  ) internal returns (uint256 role) {
    // create the new hat
    role = HATS().createHat(_admin, _details, _maxSupply, _eligibility, _toggle, _mutable, _imageURI);
    // store the role by setting its minStake
    _setMinStake(role, _minStake);
  }

  function _setMinStake(uint256 _hat, uint112 _minStake) internal {
    minStakes[_hat] = _minStake;

    emit MinStakeSet(_hat, _minStake);
  }

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
    // eligible if member stake for the hat being >= minStake
    eligible = _isInternallyEligible(_hatId, _member);
    // standing is the inverse of badStandings
    standing = !badStandings[_hatId][_member];
  }

  function _isInternallyEligible(uint256 _hat, address _member) internal view returns (bool) {
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

  function setStanding(uint256 _hat, address _member, bool _standing) external validRole(_hat) onlyJudge {
    // standing is the inverse of badStandings
    badStandings[_hat][_member] = !_standing;
  }

  /*//////////////////////////////////////////////////////////////
                          STAKING LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Stakes shares for a role, defined by a hatId
   */
  function stakeForRole(uint256 _hat, uint112 _amount) external validRole(_hat) {
    // add _amount to _hat's stake for msg.sender; we need to do this before checking eligibility since its a criterion
    _addStake(msg.sender, _hat, _amount);

    /**
     * @dev Caller must be explicitly eligible for _hat in order to wear it. If _hat's eligibility module
     * is this contract, the only criterion is sufficient stake. If it's another contract, we need to check for explicit
     * eligibility.
     * NOTE: Developers of eligibility modules for stakeable roles should include a check to this contract as one of
     * their eligibility criteria
     */

    // get _hat's eligibility module
    address eligibility = HATS().getHatEligibilityModule(_hat);

    if (eligibility == address(this)) {
      // check this contract for eligibility
      if (!_isInternallyEligible(_hat, msg.sender)) revert InsufficientStake();
    } else {
      // check the _hat's eligibility module for explicity eligibility
      if (!_isExplicitlyEligible(_hat, eligibility, msg.sender)) revert NotEligible();
    }

    // calculate msg.sender's staking proxy address
    address proxy = _calculateStakingProxyAddress(msg.sender);

    // transfer _amount of shares from msg.sender to their staking proxy
    _transferShares(msg.sender, proxy, _amount);

    // delegate shares from proxy back to msg.sender
    _delegateFromProxy(msg.sender, proxy);

    // log the stake
    emit Staked(msg.sender, _hat, _amount);
  }

  /**
   * @notice Begins the process of unstaking shares from a role, defined by a hatId
   */
  // TODO test whether we need the validRole modifier here
  function beginUnstakeFromRole(uint256 _hat, uint112 _amount) external validRole(_hat) {
    // check if caller is in bad standing for _hat and slash their stake if so
    if (!HATS().isInGoodStanding(msg.sender, _hat)) {
      _slashStake(msg.sender, _hat);
      return;
    }

    Stake storage stake = roleStakes[_hat][msg.sender];

    // caller must have sufficient stake for _hat
    if (stake.stakedAmount < _amount) revert InsufficientStake();
    // caller must not be in cooldown period for _hat
    if (stake.unstakingAmount > 0) revert CooldownNotEnded();

    // otherwise, proceed with the unstake, moving their stake for _hat to the cooldown queue
    stake.unstakingAmount = _amount;
    stake.canUnstakeAfter = uint32(block.timestamp) + cooldownPeriod();
    stake.stakedAmount -= _amount;

    // log the unstake initiation
    emit UnstakeBegun(msg.sender, _hat, _amount);
  }

  /**
   * @notice Completes the process of unstaking shares from a role, defined by a hatId
   */
  // TODO test whether we need the validRole modifier here
  function completeUnstakeFromRole(uint256 _hat, address _member) external validRole(_hat) {
    // check if caller is in bad standing for _hat and slash their stake if so
    if (!HATS().isInGoodStanding(_member, _hat)) {
      _slashStake(_member, _hat);
      return;
    }

    // remove their stake from the cooldown queue
    Stake storage stake = roleStakes[_hat][_member];
    uint112 amount = stake.unstakingAmount;
    stake.unstakingAmount = 0;
    stake.canUnstakeAfter = 0;

    // remove the cooled-down stake from their total
    memberStakes[_member] -= amount;

    // transfer their amount of shares from the msg.sender's staking proxy to msg.sender
    _transferShares(_calculateStakingProxyAddress(_member), _member, amount);

    // log the unstake
    emit UnstakeCompleted(_member, _hat, amount);
  }

  /**
   * @notice Slashes a member's stake for a role, if they are in bad standing
   */
  function slash(address _member, uint256 _hat) external validRole(_hat) {
    // member must be in bad standing for _hat
    if (HATS().isInGoodStanding(_member, _hat)) revert NotInBadStanding();

    // slash their stake
    _slashStake(_member, _hat);
  }

  function _addStake(address _member, uint256 _hat, uint112 _amount) internal {
    // add _amount to _member's stake for _hat
    roleStakes[_hat][_member].stakedAmount += _amount;

    // add _amount to _member's total stake
    memberStakes[_member] += _amount;

    // log the stake
    emit Staked(_member, _hat, _amount);
  }

  function _slashStake(address _member, uint256 _hat) internal {
    // set _member's stake for _hat to 0
    Stake storage stake = roleStakes[_hat][_member];
    uint112 amount = stake.stakedAmount;
    stake.stakedAmount = 0;

    // subtract _amount from _member's total stake
    memberStakes[_member] -= amount;

    // clear any cooldown for _hat
    stake.unstakingAmount = 0;
    stake.canUnstakeAfter = 0;

    // burn the shares
    _burnShares(_member, amount);

    // burn their hat (it's already been dynamically revoked by the eligibility module, but now we fully burn it)
    HATS().checkHatWearerStatus(_hat, _member);

    // log the slash
    emit Slashed(_member, _hat, amount);
  }

  /*//////////////////////////////////////////////////////////////
                          PUBLIC GETTERS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Derives the unstaking cooldown period as the sum of the {BAAL}'s voting and grace periods, and the
   * `cooldownBuffer`. This should give the {BAAL} enough time to place a misbehaving member in bad standing for a role
   * before they can complete their unstake.
   */
  function cooldownPeriod() public view returns (uint32) {
    return uint32(BAAL().votingPeriod() + BAAL().gracePeriod()) + cooldownBuffer;
  }

  function getStakedSharesAndProxy(address _member) public view returns (uint256 amount, address stakingProxy) {
    stakingProxy = _calculateStakingProxyAddress(_member);
    amount = SHARES_TOKEN.balanceOf(stakingProxy);
  }

  /*//////////////////////////////////////////////////////////////
                          SHAMAN LOGIC
  //////////////////////////////////////////////////////////////*/

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

  function _burnShares(address _from, uint112 _amount) internal {
    uint256[] memory amounts = new uint256[](1);
    address[] memory members = new address[](1);
    amounts[0] = uint256(_amount);
    members[0] = _calculateStakingProxyAddress(_from);
    BAAL().burnShares(members, amounts);
  }

  function _delegateFromProxy(address _member, address _proxy) internal {
    // deploy a staking proxy for _member, if they don't have one
    if (_proxy.code.length == 0) _deployStakingProxy(_member);
    // have the proxy delegate to the _member
    StakingProxy(_proxy).delegate();
  }

  /*//////////////////////////////////////////////////////////////
                      SHARE STAKING PROXY LOGIC
  //////////////////////////////////////////////////////////////*/

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
   * @dev Encode the args for the staking proxy: `address(this)`, `address(SHARES_TOKEN)`, and `_member`
   */
  function _encodeArgs(address _member) internal view returns (bytes memory) {
    return abi.encode(address(this), address(SHARES_TOKEN), _member);
  }

  /**
   * @dev Generate a salt for the share staking proxy
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

  modifier onlyHatAdmin() {
    if (!HATS().isAdminOfHat(msg.sender, hatId())) revert NotHatAdmin();
    _;
  }

  modifier validRole(uint256 _hat) {
    if (minStakes[_hat] == 0) revert InvalidRole();
    _;
  }

  modifier hatIsMutable() {
    bool mutable_;
    (,,,,,,, mutable_,) = HATS().viewHat(hatId());
    if (!mutable_) revert HatImmutable();
    _;
  }
}
