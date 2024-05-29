// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.13;

library LibHatId {
  error MaxLevelsReached();

  /// @dev Number of bits of address space for tophat ids, ie the tophat domain
  uint256 internal constant TOPHAT_ADDRESS_SPACE = 32;

  /// @dev Number of bits of address space for each level below the tophat
  uint256 internal constant LOWER_LEVEL_ADDRESS_SPACE = 16;

  /// @dev Maximum number of levels below the tophat, ie max tree depth
  ///      (256 - TOPHAT_ADDRESS_SPACE) / LOWER_LEVEL_ADDRESS_SPACE;
  uint256 internal constant MAX_LEVELS = 14;

  /// @notice Constructs a valid hat id for a new hat underneath a given admin
  /// @dev Reverts if the admin has already reached `MAX_LEVELS`
  /// @param _admin the id of the admin for the new hat
  /// @param _newHat the uint16 id of the new hat
  /// @return id The constructed hat id
  function buildHatId(uint256 _admin, uint16 _newHat) public pure returns (uint256 id) {
    uint256 mask;
    for (uint256 i = 0; i < MAX_LEVELS;) {
      unchecked {
        mask = uint256(
          type(uint256).max
          // should not overflow given known constants
          >> (TOPHAT_ADDRESS_SPACE + (LOWER_LEVEL_ADDRESS_SPACE * i))
        );
      }
      if (_admin & mask == 0) {
        unchecked {
          id = _admin
            | (
              uint256(_newHat)
              // should not overflow given known constants
              << (LOWER_LEVEL_ADDRESS_SPACE * (MAX_LEVELS - 1 - i))
            );
        }
        return id;
      }

      // should not overflow based on < MAX_LEVELS stopping condition
      unchecked {
        ++i;
      }
    }

    // if _admin is already at MAX_LEVELS, child hats are not possible, so we revert
    revert MaxLevelsReached();
  }

  /// @notice Identifies the level a given hat in its local hat tree
  /// @dev Similar to getHatLevel, but does not account for linked trees
  /// @param _hatId the id of the hat in question
  /// @return level The local level, from 0 to 14
  function getLocalHatLevel(uint256 _hatId) public pure returns (uint32 level) {
    if (_hatId & uint256(type(uint224).max) == 0) return 0;
    if (_hatId & uint256(type(uint208).max) == 0) return 1;
    if (_hatId & uint256(type(uint192).max) == 0) return 2;
    if (_hatId & uint256(type(uint176).max) == 0) return 3;
    if (_hatId & uint256(type(uint160).max) == 0) return 4;
    if (_hatId & uint256(type(uint144).max) == 0) return 5;
    if (_hatId & uint256(type(uint128).max) == 0) return 6;
    if (_hatId & uint256(type(uint112).max) == 0) return 7;
    if (_hatId & uint256(type(uint96).max) == 0) return 8;
    if (_hatId & uint256(type(uint80).max) == 0) return 9;
    if (_hatId & uint256(type(uint64).max) == 0) return 10;
    if (_hatId & uint256(type(uint48).max) == 0) return 11;
    if (_hatId & uint256(type(uint32).max) == 0) return 12;
    if (_hatId & uint256(type(uint16).max) == 0) return 13;
    return 14;
  }

  /// @notice Checks whether a hat is a topHat in its local hat tree
  /// @dev Similar to isTopHat, but does not account for linked trees
  /// @param _hatId The hat in question
  /// @return _isLocalTopHat Whether the hat is a topHat for its local tree
  function isLocalTopHat(uint256 _hatId) public pure returns (bool _isLocalTopHat) {
    _isLocalTopHat = _hatId > 0 && uint224(_hatId) == 0;
  }

  function isValidHatId(uint256 _hatId) public pure returns (bool validHatId) {
    // valid top hats are valid hats
    if (isLocalTopHat(_hatId)) return true;

    uint32 level = getLocalHatLevel(_hatId);
    uint256 admin;
    // for each subsequent level up the tree, check if the level is 0 and return false if so
    for (uint256 i = level - 1; i > 0;) {
      // truncate to find the (truncated) admin at this level
      // we don't need to check _hatId's own level since getLocalHatLevel already ensures that its non-empty
      admin = _hatId >> (LOWER_LEVEL_ADDRESS_SPACE * (MAX_LEVELS - i));
      // if the lowest level of the truncated admin is empty, the hat id is invalid
      if (uint16(admin) == 0) return false;

      unchecked {
        --i;
      }
    }
    // if there are no empty levels, return true
    return true;
  }

  /// @notice Gets the hat id of the admin at a given level of a given hat
  ///         local to the tree containing the hat.
  /// @param _hatId the id of the hat in question
  /// @param _level the admin level of interest
  /// @return admin The hat id of the resulting admin
  function getAdminAtLocalLevel(uint256 _hatId, uint32 _level) public pure returns (uint256 admin) {
    uint256 mask = type(uint256).max << (LOWER_LEVEL_ADDRESS_SPACE * (MAX_LEVELS - _level));

    admin = _hatId & mask;
  }

  /// @notice Gets the tophat domain of a given hat
  /// @dev A domain is the identifier for a given hat tree, stored in the first 4 bytes of a hat's id
  /// @param _hatId the id of the hat in question
  /// @return domain The domain of the hat's tophat
  function getTopHatDomain(uint256 _hatId) public pure returns (uint32 domain) {
    domain = uint32(_hatId >> (LOWER_LEVEL_ADDRESS_SPACE * MAX_LEVELS));
  }
}
