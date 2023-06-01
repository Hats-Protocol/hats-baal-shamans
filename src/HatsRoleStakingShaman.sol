// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// import { console2 } from "forge-std/Test.sol"; // remove before deploy
import { HatsModule, IHats, Clone } from "hats-module/HatsModule.sol";
import { LibClone } from "solady/utils/LibClone.sol";
import { IBaal } from "baal/interfaces/IBaal.sol";
import { IBaalToken } from "baal/interfaces/IBaalToken.sol";
import { IHatsEligibility } from "hats-protocol/Interfaces/IHatsEligibility.sol";
import { IHatsToggle } from "hats-protocol/Interfaces/IHatsToggle.sol";
import { HatsIdUtilities } from "hats-protocol/HatsIdUtilities.sol";

contract StakingProxy is Clone {
  error NotRoleStakingShaman();

  function ROLE_STAKING_SHAMAN() public pure returns (address) {
    return _getArgAddress(0);
  }

  function SHARES_TOKEN() public pure returns (IBaalToken) {
    return IBaalToken(_getArgAddress(20));
  }

  function MEMBER() public pure returns (address) {
    return _getArgAddress(40);
  }

  function delegate() external {
    if (msg.sender != ROLE_STAKING_SHAMAN()) revert NotRoleStakingShaman();

    SHARES_TOKEN().delegate(MEMBER());
  }
}

/**
 * @title Hats Role Staking Shaman
 * @notice TODO
 * @author Haberdasher Labs
 * @author @spengrah
 * @dev This contract inherits from the HatsModule contract, and is meant to be deployed as a clone from the
 * HatsModuleFactory.
 */
contract HatsRoleStakingShaman is HatsModule, IHatsEligibility, IHatsToggle {
  /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
  //////////////////////////////////////////////////////////////*/

  error NotBaal();
  error RoleAlreadyAdded();
  error RoleNotAdded();
  error InvalidRole();

  /*//////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  event Staked(address member, uint256 hat, uint256 amount);
  event UnstakeBegun(address member, uint256 hat, uint256 amount);
  event UnstakeCompleted(address member, uint256 hat, uint256 amount);
  event Slashed(address member, uint256 hat, uint256 amount);
  event MinStakeSet(uint256 _hat, uint256 _minStake);

  /*//////////////////////////////////////////////////////////////
                            DATA MODELS
  //////////////////////////////////////////////////////////////*/

  /**
   * @dev Packed into a single storage slot
   * @custom:member amount The amount of tokens staked
   * @custom:member slashed Whether the stake has been slashed
   */
  struct Stake {
    uint256 amount; // 31 bytes
    bool slashed; // 1 byte
  }

  /**
   * @notice Data for an unstaking cooldown period
   * @custom:member amount The amount of tokens to be unstaked
   * @custom:member endsAt When the cooldown period ends, in seconds since the epoch
   */
  struct Cooldown {
    uint256 amount;
    uint256 endsAt;
  }

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
   * Offset | Constant           | Type    | Length | Source Contract    |
   * --------------------------------------------------------------------|
   * 0      | IMPLEMENTATION     | address | 20     | HatsModule         |
   * 20     | HATS               | address | 20     | HatsModule         |
   * 40     | hatId              | uint256 | 32     | HatsModule         |
   * 72     | BAAL               | address | 20     | this               |
   * 92     | OWNER_HAT          | uint256 | 32     | this               |
   * 124    | STAKING_PROXY_IMPL | address | 20     | this               |
   * --------------------------------------------------------------------+
   */

  /// @dev The hat this shaman wears, that will be the admin of the hats this shaman creates and manages
  // function hatId() public pure returns (uint256) {
  //   return _getArgUint256(40);
  // }

  function BAAL() public pure returns (IBaal) {
    return IBaal(_getArgAddress(72));
  }

  function OWNER_HAT() public pure returns (uint256) {
    return _getArgUint256(92);
  }

  function STAKING_PROXY_IMPL() public pure returns (address) {
    return _getArgAddress(124);
  }

  /**
   * @notice The hats tree (aka tophat domain) that incldues the hats this shaman creates and manages
   * @dev Cleans the last 224 bits of the hatId, leaving only the first 32 bits, which are the tophat domain
   */
  function treeId() public pure returns (uint256) {
    return hatId() >> 224 << 224;
  }

  /**
   * @dev These are not stored as immutable args in order to enable instances to be set as shamans in new Baal
   * deployments via `initializationActions`, which is not possible if these values determine an instance's address.
   */
  IBaalToken public SHARES_TOKEN;
  IBaalToken public LOOT_TOKEN;

  /*//////////////////////////////////////////////////////////////
                          MUTABLE STATE
  //////////////////////////////////////////////////////////////*/

  mapping(uint256 hat => uint256 minStake) public minStakes;

  mapping(uint256 hat => mapping(address member => Stake stake)) public roleStakes;

  mapping(address member => uint256 totalStaked) public memberStakes;

  mapping(uint256 hat => mapping(address member => Cooldown cooldown)) public cooldowns;

  // TODO figure out how to set the cooldown period -- should it be related to the BAAL's voting+grace period?
  uint256 public cooldownPeriod;

  /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  constructor(string memory _version) HatsModule(_version) { }

  /*//////////////////////////////////////////////////////////////
                          INITIALIZER
  //////////////////////////////////////////////////////////////*/

  /**
   * @inheritdoc HatsModule
   */
  function setUp(bytes calldata _initData) public override initializer {
    SHARES_TOKEN = IBaalToken(BAAL().sharesToken());
    LOOT_TOKEN = IBaalToken(BAAL().lootToken());

    uint256 cooldownPeriod_ = abi.decode(_initData, (uint256));
    cooldownPeriod = cooldownPeriod_;
  }

  /*//////////////////////////////////////////////////////////////
                          HATTER LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Adds a staking requirement to a role, defined by a hatId
   */
  function createRole(
    string memory _details,
    uint32 _maxSupply,
    address _eligibility,
    address _toggle,
    bool _mutable,
    string memory _imageURI,
    uint32 _minStake
  ) external onlyBaal {
    // create the new role
    _createRole(hatId(), _details, _maxSupply, _eligibility, _toggle, _mutable, _imageURI, _minStake);
  }

  function createSubRole(
    uint256 _admin,
    string memory _details,
    uint32 _maxSupply,
    address _eligibility,
    address _toggle,
    bool _mutable,
    string memory _imageURI,
    uint32 _minStake
  ) external onlyBaal {
    // create the new role
    _createRole(_admin, _details, _maxSupply, _eligibility, _toggle, _mutable, _imageURI, _minStake);
  }

  function addRole(uint256 _hat, uint256 _minStake) external onlyBaal {
    // ensure the role is in hatId()'s branch
    if (!_inBranch(_hat)) revert InvalidRole();
    // ensure the role hasn't already been added or created
    if (minStakes[_hat] != 0) revert RoleAlreadyAdded();

    _setMinStake(_hat, _minStake);
  }

  /**
   * @notice Removes the staking requirement from a role, defined by a hatId
   */
  function removeRole(uint256 _hat) external onlyBaal {
    // ensure the role has been added
    if (minStakes[_hat] == 0) revert RoleNotAdded();

    _setMinStake(_hat, 0);
  }

  /**
   * @notice Sets the staking requirement for a role, defined by a hatId
   */
  function setMinStake(uint256 _hat, uint256 _minStake) external onlyBaal {
    // ensure the role has been added
    if (minStakes[_hat] == 0) revert RoleNotAdded();

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
    uint32 _minStake
  ) internal returns (uint256 role) {
    // create the new hat
    role = HATS().createHat(_admin, _details, _maxSupply, _eligibility, _toggle, _mutable, _imageURI);
    // store the role by setting its minStake
    _setMinStake(role, _minStake);
  }

  function _setMinStake(uint256 _hat, uint256 _minStake) internal {
    minStakes[_hat] = _minStake;

    emit MinStakeSet(_hat, _minStake);
  }

  function _inBranch(uint256 _hat) internal pure returns (bool) {
    // TODO use HatIdUtilities to calculate this
  }

  /*//////////////////////////////////////////////////////////////
                        ELIGIBILITY LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IHatsEligibility
  function getWearerStatus(address _member, uint256 _hatId)
    external
    view
    override
    returns (bool eligibility, bool standing)
  {
    // TODO
  }

  /*//////////////////////////////////////////////////////////////
                          TOGGLE LOGIC
  //////////////////////////////////////////////////////////////*/
  // TODO does this contract really need to be a toggle module?
  /// @inheritdoc IHatsToggle
  function getHatStatus(uint256 _hatId) external view override returns (bool active) { }

  /*//////////////////////////////////////////////////////////////
                          STAKING LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Stakes shares for a role, defined by a hatId
   */
  function stakeForRole(uint256 _hat, uint256 _amount) external {
    // add _amount to _hat's stake for msg.sender
    _addStake(msg.sender, _hat, _amount);

    // TODO check if msg.sender is eligible for _hat
    // if not, revert

    // calculate staking proxy address
    address proxy = _calculateStakingProxyAddress(msg.sender);

    // transfer _amount of shares from msg.sender to their staking proxy
    _transferShares(msg.sender, proxy, _amount);

    // delegate shares back to msg.sender
    _delegate(msg.sender, proxy);

    // log the stake
    emit Staked(msg.sender, _hat, _amount);
  }

  /**
   * @notice Begins the process of unstaking shares from a role, defined by a hatId
   */
  function beginUnstakeFromRole(uint256 _hat) external {
    // TODO check if _member is in bad standing for _hat

    // if so, slash their stake for _hat and log the slash
    _slashStake(msg.sender, _hat);

    // if not, move their stake for _hat to the cooldown queue
    uint256 amount = roleStakes[_hat][msg.sender].amount;
    // TODO

    // log the unstake initiation
    emit UnstakeBegun(msg.sender, _hat, amount);
  }

  /**
   * @notice Completes the process of unstaking shares from a role, defined by a hatId
   */
  function completeUnstakeFromRole(uint256 _hat) external {
    // TODO check if _member is in bad standing for _hat

    // if so, slash their stake for _hat and log the slash
    _slashStake(msg.sender, _hat);

    // if not...
    uint256 amount = roleStakes[_hat][msg.sender].amount;
    // remove their amount from the cooldown queue

    // transfer their amount of shares from the msg.sender's staking proxy to msg.sender
    _transferShares(_calculateStakingProxyAddress(msg.sender), msg.sender, amount);

    // log the unstake
    emit UnstakeCompleted(msg.sender, _hat, amount);
  }

  /**
   * @notice Slashes a member's stake for a role, defined by a hatId
   */
  function slash(address _member, uint256 _hat) external {
    // check if _member is in bad standing for _hat
    _slashStake(_member, _hat);

    // burn their hat
    HATS().checkHatWearerStatus(_hat, _member);
  }

  function _addStake(address _member, uint256 _hat, uint256 _amount) internal {
    // add _amount to _member's stake for _hat
    roleStakes[_hat][_member].amount += _amount;

    // add _amount to _member's total stake
    memberStakes[_member] += _amount;

    // log the stake
    emit Staked(_member, _hat, _amount);
  }

  function _slashStake(address _member, uint256 _hat) internal {
    uint256 amount = roleStakes[_hat][_member].amount;

    // set _member's stake for _hat to 0
    roleStakes[_hat][_member].amount = 0;

    // subtract _amount from _member's total stake
    memberStakes[_member] -= amount;

    // burn the shares
    _burnShares(_member, amount);

    // log the slash
    emit Slashed(_member, _hat, amount);
  }

  /*//////////////////////////////////////////////////////////////
                          SHAMAN LOGIC
  //////////////////////////////////////////////////////////////*/

  function _transferShares(address _from, address _to, uint256 _amount) internal {
    uint256[] memory amounts = new uint256[](1);
    address[] memory members = new address[](1);
    amounts[0] = _amount;

    // burn from _from
    members[0] = _from;
    BAAL().burnShares(members, amounts);

    // mint to _to
    members[0] = _to;
    BAAL().mintShares(members, amounts);
  }

  function _burnShares(address _from, uint256 _amount) internal {
    uint256[] memory amounts = new uint256[](1);
    address[] memory members = new address[](1);
    amounts[0] = _amount;
    members[0] = _calculateStakingProxyAddress(_from);
    BAAL().burnShares(members, amounts);
  }

  function _delegate(address _member, address _proxy) internal {
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
                          OWNER FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function _wearsOwnerHat() internal view returns (bool) {
    return HATS().isWearerOfHat(msg.sender, OWNER_HAT());
  }

  /*//////////////////////////////////////////////////////////////
                            MODIFIERS
  //////////////////////////////////////////////////////////////*/

  modifier onlyBaal() {
    if (msg.sender != address(BAAL())) revert NotBaal();
    _;
  }
}
