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

  error NotWearingMemberHat();
  error StillWearsMemberHat(address member);
  error NoLoot();
  error NoShares(address member);
  error NotMember(address nonMember);
  error NotInBadStanding(address member);

  /*//////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  event Onboarded(address member, uint256 sharesMinted);
  event Offboarded(address[] members, uint256[] sharesDownConverted);
  event Reboarded(address member, uint256 lootUpConverted);
  event Kicked(address[] members, uint256[] sharesBurned, uint256[] lootBurned);

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
   * 92      | STARTING_SHARES | uint256 | 32      | this                |
   * 124     | LOOT_TOKEN      | address | 20      | this                |
   * 144     | SHARES_TOKEN    | address | 20      | this                |
   * --------------------------------------------------------------------+
   */

  function BAAL() public pure returns (IBaal) {
    return IBaal(_getArgAddress(72));
  }

  function STARTING_SHARES() public pure returns (uint256) {
    return _getArgUint256(92);
  }

  function LOOT_TOKEN() public pure returns (IBaalToken) {
    return IBaalToken(_getArgAddress(124));
  }

  function SHARES_TOKEN() public pure returns (IBaalToken) {
    return IBaalToken(_getArgAddress(144));
  }

  /*//////////////////////////////////////////////////////////////

                          CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  constructor(string memory _version) HatsModule(_version) { }

  /*//////////////////////////////////////////////////////////////
                          SHAMAN LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Onboards the caller to the DAO, if they are wearing the member hat. New members receive a starting number
   * of shares.
   */
  function onboard() external wearsHat(msg.sender) {
    uint256[] memory amounts = new uint256[](1);
    address[] memory members = new address[](1);
    amounts[0] = STARTING_SHARES();
    members[0] = msg.sender;

    BAAL().mintShares(members, amounts);

    emit Onboarded(msg.sender, STARTING_SHARES());
  }

  /**
   * @notice Offboards a batch of members from the DAO, if they are not wearing the member hat. Offboarded members
   * lose their voting power, but keep a record of their previous shares in the form of loot.
   * @param _members The addresses of the members to offboard.
   */
  function offboard(address[] calldata _members) external {
    uint256 length = _members.length;
    uint256[] memory amounts = new uint256[](length);

    for (uint256 i; i < length;) {
      // TODO test gas savings from storing amount and member in memory
      if (HATS().isWearerOfHat(_members[i], hatId())) revert StillWearsMemberHat(_members[i]);

      amounts[i] = SHARES_TOKEN().balanceOf(_members[i]);

      if (amounts[i] == 0) revert NoShares(_members[i]);

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
    if (HATS().isWearerOfHat(_member, hatId())) revert StillWearsMemberHat(_member);

    address[] memory members = new address[](1);
    uint256[] memory amounts = new uint256[](1);
    members[0] = _member;
    amounts[0] = SHARES_TOKEN().balanceOf(_member);

    if (amounts[0] == 0) revert NoShares(_member);

    BAAL().burnShares(members, amounts);
    BAAL().mintLoot(members, amounts);

    emit Offboarded(members, amounts);
  }

  /**
   * @notice Reboards the caller to the DAO, if they were previously offboarded but are once again wearing the member
   * hat. Reboarded members regaing their voting power by having their loot up-converted to shares.
   */
  function reboard() external wearsHat(msg.sender) {
    uint256 amount = LOOT_TOKEN().balanceOf(msg.sender);
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

    for (uint256 i; i < length;) {
      // TODO test gas savings from storing member in memory
      if (HATS().isInGoodStanding(_members[i], hatId())) revert NotInBadStanding(_members[i]);

      shares[i] = SHARES_TOKEN().balanceOf(_members[i]);
      loots[i] = LOOT_TOKEN().balanceOf(_members[i]);

      if (shares[0] + loots[0] == 0) revert NotMember(_members[0]);

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
    shares[0] = SHARES_TOKEN().balanceOf(_member);
    loots[0] = LOOT_TOKEN().balanceOf(_member);

    if (shares[i] + loots[i] == 0) revert NotMember(_members[i]);

    BAAL().burnShares(members, shares);
    BAAL().burnLoot(members, loots);

    emit Kicked(members, shares, loots);
  }

  /*//////////////////////////////////////////////////////////////
                          MODIFIERS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Reverts if the caller is not wearing the member hat.
   */
  modifier wearsHat(address _user) {
    if (!HATS().isWearerOfHat(_user, hatId())) revert NotWearingMemberHat();
    _;
  }
}
