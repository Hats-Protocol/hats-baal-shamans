// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// import { console2 } from "forge-std/Test.sol"; // remove before deploy
import { HatsModule } from "hats-module/HatsModule.sol";
import { IBaal } from "baal/interfaces/IBaal.sol";
import { IBaalToken } from "baal/interfaces/IBaalToken.sol";

/**
 * @title Hats Onboarding Shaman
 * @notice A Baal manager shaman that allows onboarding, offboarding, and other DAO member management
 * based on Hats Protocol hats. Members must wear the member hat to onboard or reboard, can be offboarded if
 * they no longer wear the member hat, and kicked completely if they are in bad standing for the member hat.
 * @author Haberdasher Labs
 * @author @spengrah
 * @dev This contract inherits from the HatsModule contract, and is meant to be deployed as a clone from the
 * HatsModuleFactory.
 */
contract HatsOnboardingShaman is HatsModule {
  /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
  //////////////////////////////////////////////////////////////*/

  error AlreadyBoarded();
  error NotWearingMemberHat();
  error NotWearingOwnerHat();
  error StillWearsMemberHat(address member);
  error NoLoot();
  error NoShares(address member);
  error NotMember(address nonMember);
  error NotInBadStanding(address member);
  error BadStartingShares();

  /*//////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  event Onboarded(address member, uint256 sharesMinted);
  event Offboarded(address[] members, uint256[] sharesDownConverted);
  event Reboarded(address member, uint256 lootUpConverted);
  event Kicked(address[] members, uint256[] sharesBurned, uint256[] lootBurned);
  event StartingSharesSet(uint256 newStartingShares);

  /*//////////////////////////////////////////////////////////////
                        INTERNAL CONSTANTS
  //////////////////////////////////////////////////////////////*/

  uint256 internal constant MIN_STARTING_SHARES = 1e18;

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
   * --------------------------------------------------------------------|
   * Offset  | Constant        | Type    | Length  | Source Contract     |
   * --------------------------------------------------------------------|
   * 0       | IMPLEMENTATION  | address | 20      | HatsModule          |
   * 20      | HATS            | address | 20      | HatsModule          |
   * 40      | hatId           | uint256 | 32      | HatsModule          |
   * 72      | BAAL            | address | 20      | this                |
   * 92      | OWNER_HAT       | uint256 | 32      | this                |
   * --------------------------------------------------------------------+
   */

  function BAAL() public pure returns (IBaal) {
    return IBaal(_getArgAddress(72));
  }

  function OWNER_HAT() public pure returns (uint256) {
    return _getArgUint256(92);
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

  uint256 public startingShares;

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

    uint256 startingShares_ = abi.decode(_initData, (uint256));

    if (startingShares_ < MIN_STARTING_SHARES) revert BadStartingShares();

    // set the starting shares
    startingShares = startingShares_;
    // no need to emit an event, as this value is emitted in the HatsModuleFactory_ModuleDeployed event
  }

  /*//////////////////////////////////////////////////////////////
                          SHAMAN LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Onboards the caller to the DAO, if they are wearing the member hat. New members receive `startingShares`
   * number of shares
   */
  function onboard() external wearsMemberHat(msg.sender) {
    if (SHARES_TOKEN.balanceOf(msg.sender) + LOOT_TOKEN.balanceOf(msg.sender) > 0) revert AlreadyBoarded();

    uint256[] memory amounts = new uint256[](1);
    address[] memory members = new address[](1);
    uint256 amount = startingShares; // save 1 SLOAD
    amounts[0] = amount;
    members[0] = msg.sender;

    BAAL().mintShares(members, amounts);
    emit Onboarded(msg.sender, amount);
  }

  /**
   * @notice Offboards a batch of members from the DAO, if they are not wearing the member hat. Offboarded members
   * lose their voting power, but keep a record of their previous shares in the form of loot.
   * @param _members The addresses of the members to offboard.
   */
  function offboard(address[] calldata _members) external {
    // TODO is there any problem if the array is empty?
    uint256 length = _members.length;
    uint256[] memory amounts = new uint256[](length);
    uint256 amount;
    address member;

    for (uint256 i; i < length;) {
      member = _members[i];
      amount = SHARES_TOKEN.balanceOf(member);

      if (amount == 0) revert NoShares(member);
      if (HATS().isWearerOfHat(member, hatId())) revert StillWearsMemberHat(member);

      amounts[i] = amount;

      unchecked {
        ++i;
      }
    }

    BAAL().burnShares(_members, amounts);
    BAAL().mintLoot(_members, amounts);

    emit Offboarded(_members, amounts);
  }

  /**
   * @notice Offboards a single member from the DAO, if they are not wearing the member hat. Offboarded members
   * lose their voting power by having their shares down-converted to loot.
   * @param _member The address of the member to offboard.
   */
  function offboard(address _member) external {
    uint256 amount = SHARES_TOKEN.balanceOf(_member);

    if (amount == 0) revert NoShares(_member);
    if (HATS().isWearerOfHat(_member, hatId())) revert StillWearsMemberHat(_member);

    address[] memory members = new address[](1);
    uint256[] memory amounts = new uint256[](1);
    members[0] = _member;
    amounts[0] = amount;

    BAAL().burnShares(members, amounts);
    BAAL().mintLoot(members, amounts);

    emit Offboarded(members, amounts);
  }

  /**
   * @notice Reboards the caller to the DAO, if they were previously offboarded but are once again wearing the member
   * hat. Reboarded members regaing their voting power by having their loot up-converted to shares.
   */
  function reboard() external wearsMemberHat(msg.sender) {
    uint256 amount = LOOT_TOKEN.balanceOf(msg.sender);
    if (amount == 0) revert NoLoot();

    address[] memory members = new address[](1);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;
    members[0] = msg.sender;

    BAAL().burnLoot(members, amounts);
    BAAL().mintShares(members, amounts);

    emit Reboarded(msg.sender, amount);
  }

  /**
   * @notice Kicks a batch of members out of the DAO completely, if they are in bad standing for the member hat.
   * Kicked members lose their voting power and any record of their previous shares; all of their shares and loot are
   * burned.
   * @param _members The addresses of the members to kick.
   */
  function kick(address[] calldata _members) external {
    uint256 length = _members.length;
    uint256[] memory shares = new uint256[](length);
    uint256[] memory loots = new uint256[](length);
    address member;
    uint256 shareAmount;
    uint256 lootAmount;

    for (uint256 i; i < length;) {
      member = _members[i];
      if (HATS().isInGoodStanding(member, hatId())) revert NotInBadStanding(member);

      shareAmount = SHARES_TOKEN.balanceOf(member);
      lootAmount = LOOT_TOKEN.balanceOf(member);

      if (shareAmount + lootAmount == 0) revert NotMember(member);

      shares[i] = shareAmount;
      loots[i] = lootAmount;

      unchecked {
        ++i;
      }
    }

    BAAL().burnShares(_members, shares);
    BAAL().burnLoot(_members, loots);

    emit Kicked(_members, shares, loots);
  }

  /**
   * @notice Kicks a single member out of the DAO completely, if they are in bad standing for the member hat.
   * Kicked members lose their voting power and any record of their previous shares; all of their shares and loot are
   * burned.
   * @param _member The address of the member to kick.
   */
  function kick(address _member) external {
    if (HATS().isInGoodStanding(_member, hatId())) revert NotInBadStanding(_member);

    address[] memory members = new address[](1);
    uint256[] memory shares = new uint256[](1);
    uint256[] memory loots = new uint256[](1);
    members[0] = _member;
    uint256 shareAmount = SHARES_TOKEN.balanceOf(_member);
    uint256 lootAmount = LOOT_TOKEN.balanceOf(_member);

    if (shareAmount + lootAmount == 0) revert NotMember(_member);

    shares[0] = shareAmount;
    loots[0] = lootAmount;

    BAAL().burnShares(members, shares);
    BAAL().burnLoot(members, loots);

    emit Kicked(members, shares, loots);
  }

  /*//////////////////////////////////////////////////////////////
                        OWNER FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Sets a new the starting shares value.
   * @param _startingShares The new starting shares value. Must be a least `1 * 10^18`.
   */
  function setStartingShares(uint256 _startingShares) external {
    if (!HATS().isWearerOfHat(msg.sender, OWNER_HAT())) revert NotWearingOwnerHat();
    if (_startingShares < MIN_STARTING_SHARES) revert BadStartingShares();
    // set the new starting shares value
    startingShares = _startingShares;
    // log the change
    emit StartingSharesSet(_startingShares);
  }

  /*//////////////////////////////////////////////////////////////
                          MODIFIERS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Reverts if the caller is not wearing the member hat.
   */
  modifier wearsMemberHat(address _user) {
    if (!HATS().isWearerOfHat(_user, hatId())) revert NotWearingMemberHat();
    _;
  }
}
