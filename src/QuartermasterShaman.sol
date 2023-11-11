// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// import { console2 } from "forge-std/Test.sol"; // remove before deploy
import { HatsModule } from "hats-module/HatsModule.sol";
import { IBaal } from "baal/interfaces/IBaal.sol";
import { IBaalToken } from "baal/interfaces/IBaalToken.sol";

/**
 * @title Quartermaster Shaman
 * @notice A Baal manager shaman that allows onboarding, offboarding, and other DAO member management
 * by the holder of the captain hat. The captain uses the quartermaster to give crew status to new members,
 * but there is a delay to avoid the captain gathering crew to avoid a mutiny.
 * @author @plor
 * @dev This contract inherits from the HatsModule contract, and is meant to be deployed as a clone from the
 * HatsModuleFactory.
 */
contract QuartermasterShaman is HatsModule {
  /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
  //////////////////////////////////////////////////////////////*/

  error NotCaptain();

  /*//////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  event OnboardedBatch(address[] members, uint256[] sharesPending, uint256 delay);
  event OffboardedBatch(address[] members, uint256[] sharesPending, uint256 delay);
  event Quartered(address[] members, uint256[] shares);
  event Unquartered(address[] members, uint256[] shares);

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
   * Offset  | Constant            | Type    | Length | Source Contract  |
   * --------------------------------------------------------------------|
   * 0       | IMPLEMENTATION      | address | 20     | HatsModule       |
   * 20      | HATS                | address | 20     | HatsModule       |
   * 40      | hatId               | uint256 | 32     | HatsModule       |
   * 72      | BAAL                | address | 20     | this             |
   * 92      | CAPTAIN_HAT         | uint256 | 32     | this             |
   * 124     | STARTING_SHARES     | uint256 | 32     | this             |
   * --------------------------------------------------------------------+
   */

  function BAAL() public pure returns (IBaal) {
    return IBaal(_getArgAddress(72));
  }

  // OWNER_HAT is renamed to CAPTAIN_HAT for this use
  // TODO I think this is wrong, this is brought from parent, captain should be initarg
  function CAPTAIN_HAT() public pure returns (uint256) {
    return _getArgUint256(92);
  }

  function STARTING_SHARES() public pure returns (uint256) {
    return _getArgUint256(124);
  }

  /**
   * @dev These are not stored as immutable args in order to enable instances to be set as shamans in new Baal
   * deployments via `initializationActions`, which is not possible if these values determine an instance's address.
   * While this means that they are stored normally in contract state, we still treat them as constants since they
   * cannot be mutated after initialization.
   */
  IBaalToken public SHARES_TOKEN;

  /*//////////////////////////////////////////////////////////////
                          MUTABLE STATE
  //////////////////////////////////////////////////////////////*/

  mapping(address => uint256) public onboardingDelay;
  mapping(address => uint256) public offboardingDelay;

  /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  constructor(string memory _version) HatsModule(_version) { }

  /*//////////////////////////////////////////////////////////////
                          INITIALIZER
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc HatsModule
  function _setUp(bytes calldata) internal override {
    SHARES_TOKEN = IBaalToken(BAAL().sharesToken());

    // no need to emit an event, as this value is emitted in the HatsModuleFactory_ModuleDeployed event
  }

  /*//////////////////////////////////////////////////////////////
                          SHAMAN LOGIC
  //////////////////////////////////////////////////////////////*/

  function onboard(address[] calldata _members) external wearsCaptainHat(msg.sender) {
    uint256 length = _members.length;
    uint256 delay = _calculateDelay();
    uint256[] memory amounts = new uint256[](length);
    address member;

    for (uint256 i; i < length;) {
      member = _members[i];
      if (onboardingDelay[member] == 0 && SHARES_TOKEN.balanceOf(member) == 0) {
        onboardingDelay[member] = delay;
        amounts[i] = STARTING_SHARES(); // else 0
      }

      
      unchecked {
        ++i;
      }
    }
    emit OnboardedBatch(_members, amounts, delay);
  }

  /**
   * @notice Offboards a batch of members from the DAO, if they are not wearing the member hat. Offboarded members
   * lose their voting power, but keep a record of their previous shares in the form of loot.
   * @param _members The addresses of the members to offboard.
   */
  function offboard(address[] calldata _members) external wearsCaptainHat(msg.sender) {
    uint256 length = _members.length;
    uint256 delay = _calculateDelay();
    uint256[] memory amounts = new uint256[](length);
    address member;
    uint256 shares;

    for (uint256 i; i < length;) {
      member = _members[i];
      shares = SHARES_TOKEN.balanceOf(member);
      if (offboardingDelay[member] == 0 && shares > 0) {
        offboardingDelay[member] = delay;
        amounts[i] = shares; // else 0
      }

      unchecked {
        ++i;
      }
    }

    emit OffboardedBatch(_members, amounts, delay);
  }

  /**
   * Executes onboarding
   */
  function quarter(address[] calldata _members) external {
    uint256 length = _members.length;
    uint256[] memory amounts = new uint256[](length);

    for (uint256 i; i < length;) {
      address member = _members[i];
      if (onboardingDelay[member] != 0 && onboardingDelay[member] <= block.timestamp) {
        delete onboardingDelay[member];
        amounts[i] = STARTING_SHARES();
      }

      unchecked {
        ++i;
      }
    }
    BAAL().mintShares(_members, amounts);
    emit Quartered(_members, amounts);
  }

  /**
   * Executes onboarding
   */
  function unquarter(address[] calldata _members) external {
    uint256 length = _members.length;
    uint256[] memory amounts = new uint256[](length);

    for (uint256 i; i < length;) {
      address member = _members[i];
      if (offboardingDelay[member] != 0 && offboardingDelay[member] <= block.timestamp) {
        delete offboardingDelay[member];
        amounts[i] = SHARES_TOKEN.balanceOf(member);
      }

      unchecked {
        ++i;
      }
    }
    BAAL().burnShares(_members, amounts);
    emit Unquartered(_members, amounts);
  }

  /*//////////////////////////////////////////////////////////////
                          PRIVATE FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Adds votingPeriod x2 to the current time to allow for mutiny delay
   */
  function _calculateDelay() private view returns (uint256 delay) {
    return block.timestamp + (2 * BAAL().votingPeriod());
  }

  /*//////////////////////////////////////////////////////////////
                          MODIFIERS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Reverts if the caller is not wearing the member hat.
   */
  modifier wearsCaptainHat(address _user) {
    if (!HATS().isWearerOfHat(_user, CAPTAIN_HAT())) revert NotCaptain();
    _;
  }
}
