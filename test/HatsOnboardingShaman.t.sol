// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test, console2 } from "forge-std/Test.sol";
import { HatsOnboardingShaman } from "../src/HatsOnboardingShaman.sol";
import { DeployImplementation } from "../script/HatsOnboardingShaman.s.sol";
import {
  IHats,
  HatsModuleFactory,
  deployModuleFactory,
  deployModuleInstance
} from "lib/hats-module/src/utils/DeployFunctions.sol";
import { IBaal } from "baal/interfaces/IBaal.sol";
import { IBaalToken } from "baal/interfaces/IBaalToken.sol";
import { IBaalSummoner } from "baal/interfaces/IBaalSummoner.sol";

contract HatsOnboardingShamanTest is DeployImplementation, Test {
  // variables inherited from DeployImplementation script
  // HatsOnboardingShaman public implementation;
  // bytes32 public SALT;

  uint256 public fork;
  uint256 public BLOCK_NUMBER = 16_947_805; // the block number where v1.hatsprotocol.eth was deployed;

  IHats public constant HATS = IHats(0x9D2dfd6066d5935267291718E8AA16C8Ab729E9d); // v1.hatsprotocol.eth
  string public FACTORY_VERSION = "factory test version";
  string public SHAMAN_VERSION = "shaman test version";

  error AlreadyBoarded();
  error NotWearingMemberHat();
  error NotOwner();
  error StillWearsMemberHat(address member);
  error NoLoot();
  error NoShares(address member);
  error NotMember(address nonMember);
  error NotInBadStanding(address member);

  event Onboarded(address member, uint256 sharesMinted);
  event Offboarded(address member, uint256 sharesDownConverted);
  event OffboardedBatch(address[] members, uint256[] sharesDownConverted);
  event Reboarded(address member, uint256 lootUpConverted);
  event Kicked(address member, uint256 sharesBurned, uint256 lootBurned);
  event KickedBatch(address[] members, uint256[] sharesBurned, uint256[] lootBurned);
  event StartingSharesSet(uint256 newStartingShares);

  function setUp() public virtual {
    // create and activate a fork, at BLOCK_NUMBER
    fork = vm.createSelectFork(vm.rpcUrl("mainnet"), BLOCK_NUMBER);

    // deploy via the script
    DeployImplementation.prepare(SHAMAN_VERSION, false); // set last arg to true to log deployment addresses
    DeployImplementation.run();
  }
}

contract WithInstanceTest is HatsOnboardingShamanTest {
  HatsModuleFactory public factory;
  HatsOnboardingShaman public shaman;
  uint256 public hatId;
  bytes public otherImmutableArgs;
  bytes public initData;

  address public zodiacFactory = 0x00000000000DC7F163742Eb4aBEf650037b1f588;
  IBaalSummoner public summoner = IBaalSummoner(0x7e988A9db2F8597735fc68D21060Daed948a3e8C);
  IBaal public baal;
  IBaalToken public sharesToken;
  IBaalToken public lootToken;
  uint256 public startingShares;
  uint256 public baalSaltNonce;

  address[] public members;
  uint256[] public sharesBurned;
  uint256[] public lootBurned;

  uint256 public tophat;
  uint256 public memberHat;
  address public eligibility = makeAddr("eligibility");
  address public toggle = makeAddr("toggle");
  address public dao = makeAddr("dao");
  address public wearer1 = makeAddr("wearer1");
  address public wearer2 = makeAddr("wearer2");
  address public nonWearer = makeAddr("nonWearer");

  address public predictedBaalAddress;
  address public predictedShamanAddress;
  address public roleStakingShaman;

  uint256 public constant MIN_STARTING_SHARES = 1e18;

  function deployInstance(address _baal, uint256 _memberHat, uint256 _ownerHat, uint256 _startingShares)
    public
    returns (HatsOnboardingShaman)
  {
    // encode the other immutable args as packed bytes
    otherImmutableArgs = abi.encodePacked(_baal, _ownerHat, roleStakingShaman);
    // encoded the initData as unpacked bytes -- for HatsOnboardingShaman, we just need any non-empty bytes
    initData = abi.encode(_startingShares);
    // deploy the instance
    return HatsOnboardingShaman(
      deployModuleInstance(factory, address(implementation), _memberHat, otherImmutableArgs, initData)
    );
  }

  function deployBaalWithShaman(string memory _name, string memory _symbol, bytes32 _saltNonce, address _shaman)
    public
    returns (IBaal)
  {
    // encode initParams
    bytes memory initializationParams = abi.encode(_name, _symbol, address(0), address(0), address(0), address(0));
    // encode initial action to set the shaman
    address[] memory shamans = new address[](1);
    uint256[] memory permissions = new uint256[](1);
    shamans[0] = _shaman;
    permissions[0] = 2; // manager only
    bytes[] memory initializationActions = new bytes[](1);
    initializationActions[0] = abi.encodeCall(IBaal.setShamans, (shamans, permissions));
    // deploy the baal
    return IBaal(
      summoner.summonBaalFromReferrer(initializationParams, initializationActions, uint256(_saltNonce), "referrer")
    );
  }

  /// @dev props to @santteegt
  function predictBaalAddress(bytes32 _saltNonce) public view returns (address baalAddress) {
    address template = summoner.template();
    bytes memory initializer = abi.encodeWithSignature("avatar()");

    bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), uint256(_saltNonce)));

    // This is how ModuleProxyFactory works
    bytes memory deployment =
    //solhint-disable-next-line max-line-length
     abi.encodePacked(hex"602d8060093d393df3363d3d373d3d3d363d73", template, hex"5af43d82803e903d91602b57fd5bf3");

    bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), zodiacFactory, salt, keccak256(deployment)));

    // NOTE: cast last 20 bytes of hash to address
    baalAddress = address(uint160(uint256(hash)));
  }

  function grantShares(address _member, uint256 _amount) public {
    vm.prank(address(baal));
    sharesToken.mint(_member, _amount);
  }

  function grantLoot(address _member, uint256 _amount) public {
    vm.prank(address(baal));
    lootToken.mint(_member, _amount);
  }

  function setUp() public virtual override {
    super.setUp();
    // set startingShares at 10
    startingShares = 10 ether; // 10 shares

    // deploy the hats module factory
    factory = deployModuleFactory(HATS, SALT, FACTORY_VERSION);

    // set up hats
    tophat = HATS.mintTopHat(dao, "tophat", "dao.eth/tophat");
    vm.startPrank(dao);
    memberHat = HATS.createHat(tophat, "memberHat", 50, eligibility, toggle, true, "dao.eth/memberHat");
    HATS.mintHat(memberHat, wearer1);
    HATS.mintHat(memberHat, wearer2);
    vm.stopPrank();

    // predict the baal's address
    predictedBaalAddress = predictBaalAddress(SALT);

    // predict the shaman's address via the hats module factory
    predictedShamanAddress = factory.getHatsModuleAddress(
      address(implementation), memberHat, abi.encodePacked(predictedBaalAddress, tophat, roleStakingShaman)
    );

    // deploy a test baal with the predicted shaman address
    baal = deployBaalWithShaman("TEST_BAAL", "TEST_BAAL", SALT, predictedShamanAddress);

    // find and set baal token addresses
    sharesToken = IBaalToken(baal.sharesToken());
    lootToken = IBaalToken(baal.lootToken());

    // deploy the shaman instance
    shaman = deployInstance(predictedBaalAddress, memberHat, tophat, startingShares);

    // ensure that the actual and predicted addresses are the same
    require(address(baal) == predictedBaalAddress, "actual and predicted baal addresses do not match");
  }
}

contract Deployment is WithInstanceTest {
  function test_setAsManagerShaman() public {
    assertEq(baal.shamans(address(shaman)), 2);
  }

  function test_version() public {
    assertEq(shaman.version(), SHAMAN_VERSION);
  }

  function test_startingShares() public {
    assertEq(shaman.startingShares(), startingShares);
  }

  function test_baal() public {
    assertEq(address(shaman.BAAL()), address(baal));
    assertEq(address(shaman.BAAL()), predictBaalAddress(SALT));
  }

  function test_sharesToken() public {
    assertEq(address(shaman.SHARES_TOKEN()), address(sharesToken));
  }

  function test_lootToken() public {
    assertEq(address(shaman.LOOT_TOKEN()), address(lootToken));
  }
}

contract Onboarding is WithInstanceTest {
  function test_wearer_canOnboard() public {
    vm.prank(wearer1);
    vm.expectEmit(true, true, true, true);
    emit Onboarded(wearer1, startingShares);
    shaman.onboard();

    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    assertEq(lootToken.balanceOf(wearer1), 0);
  }

  function test_nonWearer_reverts() public {
    vm.prank(nonWearer);
    vm.expectRevert(NotWearingMemberHat.selector);
    shaman.onboard();

    assertEq(sharesToken.balanceOf(nonWearer), 0);
    assertEq(lootToken.balanceOf(nonWearer), 0);
  }

  function test_hasLoot_reverts() public {
    uint256 amount = 50 ether;
    vm.prank(address(baal));
    lootToken.mint(wearer1, amount);

    vm.prank(wearer1);
    vm.expectRevert(AlreadyBoarded.selector);
    shaman.onboard();
  }

  function test_hasShares_reverts() public {
    uint256 amount = 50 ether;
    vm.prank(address(baal));
    sharesToken.mint(wearer1, amount);

    vm.prank(wearer1);
    vm.expectRevert(AlreadyBoarded.selector);
    shaman.onboard();
  }
}

contract Offboarding is WithInstanceTest {
  function test_single_nonWearer_member_canOffboard() public {
    vm.prank(wearer1);
    shaman.onboard();

    // they lose the hat
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, true);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));

    // they can be offboarded
    members = new address[](1);
    members[0] = wearer1;
    sharesBurned = new uint256[](1);
    sharesBurned[0] = startingShares;
    vm.expectEmit(true, true, true, true);
    emit Offboarded(wearer1, startingShares);
    shaman.offboard(wearer1);

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), startingShares);
  }

  function test_single_nonWearer_nonMember_cannotOffBoard() public {
    vm.prank(nonWearer);
    vm.expectRevert(abi.encodeWithSelector(NoShares.selector, nonWearer));
    shaman.offboard(nonWearer);

    assertEq(sharesToken.balanceOf(nonWearer), 0);
    assertEq(lootToken.balanceOf(nonWearer), 0);
  }

  function test_single_wearer_nonMember_cannotOffBoard() public {
    vm.prank(wearer1);

    vm.expectRevert(abi.encodeWithSelector(StillWearsMemberHat.selector, wearer1));
    shaman.offboard(wearer1);

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), 0);
  }

  function test_single_wearer_member_cannotOffBoard() public {
    vm.prank(wearer1);
    shaman.onboard();

    vm.expectRevert(abi.encodeWithSelector(StillWearsMemberHat.selector, wearer1));
    shaman.offboard(wearer1);

    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    assertEq(lootToken.balanceOf(wearer1), 0);
  }

  function test_batch_nonWearers_members_canOffboard() public {
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    vm.prank(wearer2);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer2), startingShares);

    // they both lose the hat
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, true);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer2, false, true);
    assertFalse(HATS.isWearerOfHat(wearer2, memberHat));

    // they can be offboarded
    members = new address[](2);
    members[0] = wearer1;
    members[1] = wearer2;
    sharesBurned = new uint256[](2);
    sharesBurned[0] = startingShares;
    sharesBurned[1] = startingShares;
    vm.expectEmit(true, true, true, true);
    emit OffboardedBatch(members, sharesBurned);
    shaman.offboard(members);

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), startingShares);
    assertEq(sharesToken.balanceOf(wearer2), 0);
    assertEq(lootToken.balanceOf(wearer2), startingShares);
  }

  function test_batch_wearer_members_reverts() public {
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    vm.prank(wearer2);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer2), startingShares);

    // just one loses the hat
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, true);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));

    // offboarding fails
    members = new address[](2);
    members[0] = wearer1;
    members[1] = wearer2;
    vm.expectRevert(abi.encodeWithSelector(StillWearsMemberHat.selector, wearer2));
    shaman.offboard(members);

    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    assertEq(lootToken.balanceOf(wearer1), 0);
    assertEq(sharesToken.balanceOf(wearer2), startingShares);
    assertEq(lootToken.balanceOf(wearer2), 0);
  }

  function test_batch_nonWearers_nonMember_reverts() public {
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);

    // they lose the hat
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, true);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));

    // offboarding nonWearer and wearer 1 fails
    members = new address[](2);
    members[0] = nonWearer;
    members[1] = wearer1;
    vm.expectRevert(abi.encodeWithSelector(NoShares.selector, nonWearer));
    shaman.offboard(members);

    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    assertEq(lootToken.balanceOf(wearer1), 0);
    assertEq(sharesToken.balanceOf(nonWearer), 0);
    assertEq(lootToken.balanceOf(nonWearer), 0);
  }

  function test_batch_wearer_nonMember_reverts() public {
    vm.prank(wearer2);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer2), startingShares);

    // they lose the hat
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer2, false, true);
    assertFalse(HATS.isWearerOfHat(wearer2, memberHat));

    // offboarding wearer 1 and wearer 2 fails
    members = new address[](2);
    members[0] = wearer1;
    members[1] = wearer2;
    vm.expectRevert(abi.encodeWithSelector(NoShares.selector, wearer1));
    shaman.offboard(members);

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), 0);
    assertEq(sharesToken.balanceOf(wearer2), startingShares);
    assertEq(lootToken.balanceOf(wearer2), 0);
  }

  function test_single_nonWearer_member_extraShares_canOffboard() public {
    vm.prank(wearer1);
    shaman.onboard();

    // they somehow earn more shares
    grantShares(wearer1, 1000);
    assertEq(sharesToken.balanceOf(wearer1), startingShares + 1000);

    // they lose the hat
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, true);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));

    // they can be offboarded
    members = new address[](1);
    members[0] = wearer1;
    sharesBurned = new uint256[](1);
    sharesBurned[0] = startingShares + 1000;
    vm.expectEmit(true, true, true, true);
    emit Offboarded(wearer1, startingShares + 1000);
    shaman.offboard(wearer1);

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), startingShares + 1000);
  }

  function test_single_nonWearer_member_extraLoot_canOffBoard() public {
    vm.prank(wearer1);
    shaman.onboard();

    // they somehow receive more loot
    grantLoot(wearer1, 1000);
    assertEq(lootToken.balanceOf(wearer1), 1000);

    // they lose the hat
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, true);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));

    // they can be offboarded
    members = new address[](1);
    members[0] = wearer1;
    sharesBurned = new uint256[](1);
    sharesBurned[0] = startingShares;
    vm.expectEmit(true, true, true, true);
    emit Offboarded(wearer1, startingShares);
    shaman.offboard(wearer1);

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), startingShares + 1000);
  }

  function test_batch_nonWearer_members_extraShares_canOffboard() public {
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    vm.prank(wearer2);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer2), startingShares);

    // one somehow earns more shares
    grantShares(wearer1, 1000);

    // they both lose the hat
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, true);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer2, false, true);
    assertFalse(HATS.isWearerOfHat(wearer2, memberHat));

    // they can be offboarded
    members = new address[](2);
    members[0] = wearer1;
    members[1] = wearer2;
    sharesBurned = new uint256[](2);
    sharesBurned[0] = startingShares + 1000;
    sharesBurned[1] = startingShares;
    vm.expectEmit(true, true, true, true);
    emit OffboardedBatch(members, sharesBurned);
    shaman.offboard(members);

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), startingShares + 1000);
    assertEq(sharesToken.balanceOf(wearer2), 0);
    assertEq(lootToken.balanceOf(wearer2), startingShares);
  }

  function test_batch_nonWearers_members_extraLoot_canOffboard() public {
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    vm.prank(wearer2);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer2), startingShares);

    // one somehow receives more loot
    grantLoot(wearer2, 1000);

    // they both lose the hat
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, true);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer2, false, true);
    assertFalse(HATS.isWearerOfHat(wearer2, memberHat));

    // they can be offboarded
    members = new address[](2);
    members[0] = wearer1;
    members[1] = wearer2;
    sharesBurned = new uint256[](2);
    sharesBurned[0] = startingShares;
    sharesBurned[1] = startingShares;
    vm.expectEmit(true, true, true, true);
    emit OffboardedBatch(members, sharesBurned);
    shaman.offboard(members);

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), startingShares);
    assertEq(sharesToken.balanceOf(wearer2), 0);
    assertEq(lootToken.balanceOf(wearer2), startingShares + 1000);
  }
}

contract Reboarding is WithInstanceTest {
  function test_wearer_withLoot_canReboard() public {
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);

    // they lose the hat and get offboarded
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, true);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));
    shaman.offboard(wearer1);
    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), startingShares);

    // then they regain the hat
    vm.prank(dao);
    HATS.mintHat(memberHat, wearer1);

    // they can reboard
    vm.prank(wearer1);
    vm.expectEmit(true, true, true, true);
    emit Reboarded(wearer1, startingShares);
    shaman.reboard();

    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    assertEq(lootToken.balanceOf(wearer1), 0);
  }

  function test_wearer_withoutLoot_reverts() public {
    // wearer1 has the hat
    assertTrue(HATS.isWearerOfHat(wearer1, memberHat));

    // they cannot reboard since they don't have any loot
    vm.prank(wearer1);
    vm.expectRevert(NoLoot.selector);
    shaman.reboard();

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), 0);
  }

  function test_nonWearer_withLoot_reverts() public {
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);

    // they lose the hat and get offboarded
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, true);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));
    shaman.offboard(wearer1);
    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), startingShares);

    // they can reboard since they don't have the hat
    vm.prank(wearer1);
    vm.expectRevert(NotWearingMemberHat.selector);
    shaman.reboard();

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), startingShares);
  }

  function test_wearer_extraLoot_canReboard() public {
    // they onboard
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);

    // they somehow earn more shares
    grantShares(wearer1, startingShares * 2);
    assertEq(sharesToken.balanceOf(wearer1), startingShares * 3);

    // they lose the hat and get offboarded
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, true);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));
    shaman.offboard(wearer1);
    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), startingShares * 3);

    // then they regain the hat
    vm.prank(dao);
    HATS.mintHat(memberHat, wearer1);

    // they can reboard
    vm.prank(wearer1);
    vm.expectEmit(true, true, true, true);
    emit Reboarded(wearer1, startingShares * 3);
    shaman.reboard();

    assertEq(sharesToken.balanceOf(wearer1), startingShares * 3);
    assertEq(lootToken.balanceOf(wearer1), 0);
  }

  function test_wearer_extraShares_canReboard() public {
    // they onboard
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);

    // they somehow receive more loot
    grantLoot(wearer1, startingShares * 2);
    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    assertEq(lootToken.balanceOf(wearer1), startingShares * 2);

    // they lose the hat and get offboarded
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, true);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));
    shaman.offboard(wearer1);
    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), startingShares * 3);

    // then they regain the hat
    vm.prank(dao);
    HATS.mintHat(memberHat, wearer1);

    // they can reboard
    vm.prank(wearer1);
    vm.expectEmit(true, true, true, true);
    emit Reboarded(wearer1, startingShares * 3);
    shaman.reboard();

    assertEq(sharesToken.balanceOf(wearer1), startingShares * 3);
    assertEq(lootToken.balanceOf(wearer1), 0);
  }
}

contract Kicking is WithInstanceTest {
  function test_single_onboarded_inBadStanding_canBeKicked() public {
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);

    // they are placed in bad standing for the hat
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, false);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));
    assertFalse(HATS.isInGoodStanding(wearer1, memberHat));

    // they can be kicked
    members = new address[](1);
    sharesBurned = new uint256[](1);
    lootBurned = new uint256[](1);
    members[0] = wearer1;
    sharesBurned[0] = startingShares;
    lootBurned[0] = 0;
    vm.expectEmit(true, true, true, true);
    emit Kicked(wearer1, startingShares, 0);
    shaman.kick(wearer1);

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), 0);
  }

  function test_single_offboarded_inBadStanding_canBeKicked() public {
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);

    // they lose the hat, get placed in bad standing, and get offboarded
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, false);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));
    assertFalse(HATS.isInGoodStanding(wearer1, memberHat));

    shaman.offboard(wearer1);
    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), startingShares);

    // they can be kicked
    members = new address[](1);
    sharesBurned = new uint256[](1);
    lootBurned = new uint256[](1);
    members[0] = wearer1;
    sharesBurned[0] = 0;
    lootBurned[0] = startingShares;
    vm.expectEmit(true, true, true, true);
    emit Kicked(wearer1, 0, startingShares);
    shaman.kick(wearer1);

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), 0);
  }

  function test_single_sharesAndLoot_inBadStanding_canBeKicked() public {
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);

    // they lose the hat, get placed in bad standing, and get offboarded
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, false);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));
    assertFalse(HATS.isInGoodStanding(wearer1, memberHat));

    shaman.offboard(wearer1);
    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), startingShares);

    // they somehow earn some additional shares
    grantShares(wearer1, startingShares / 2);

    // they can be kicked
    members = new address[](1);
    sharesBurned = new uint256[](1);
    lootBurned = new uint256[](1);
    members[0] = wearer1;
    sharesBurned[0] = startingShares / 2;
    lootBurned[0] = startingShares;
    vm.expectEmit(true, true, true, true);
    emit Kicked(wearer1, startingShares / 2, startingShares);
    shaman.kick(wearer1);

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), 0);
  }

  function test_single_inGoodStanding_reverts() public {
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);

    // they are in good standing for the hat
    assertTrue(HATS.isWearerOfHat(wearer1, memberHat));
    assertTrue(HATS.isInGoodStanding(wearer1, memberHat));

    // they cannot be kicked
    vm.expectRevert(abi.encodeWithSelector(NotInBadStanding.selector, wearer1));
    shaman.kick(wearer1);

    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    assertEq(lootToken.balanceOf(wearer1), 0);
  }

  function test_single_nonMember_reverts() public {
    // they are in bad standing
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, nonWearer, false, false);

    // but they are not a member
    assertFalse(HATS.isWearerOfHat(nonWearer, memberHat));
    assertFalse(HATS.isInGoodStanding(nonWearer, memberHat));

    // they cannot be kicked
    vm.expectRevert(abi.encodeWithSelector(NotMember.selector, nonWearer));
    shaman.kick(nonWearer);

    assertEq(sharesToken.balanceOf(nonWearer), 0);
    assertEq(lootToken.balanceOf(nonWearer), 0);
  }

  function test_batch_onBoarded_inBadStanding_canBeKicked() public {
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    vm.prank(wearer2);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer2), startingShares);

    // they are both placed in bad standing for the hat
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, false);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));
    assertFalse(HATS.isInGoodStanding(wearer1, memberHat));
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer2, false, false);
    assertFalse(HATS.isWearerOfHat(wearer2, memberHat));
    assertFalse(HATS.isInGoodStanding(wearer2, memberHat));

    // they can both be kicked
    members = new address[](2);
    sharesBurned = new uint256[](2);
    lootBurned = new uint256[](2);
    members[0] = wearer1;
    members[1] = wearer2;
    sharesBurned[0] = startingShares;
    sharesBurned[1] = startingShares;
    lootBurned[0] = 0;
    lootBurned[1] = 0;
    vm.expectEmit(true, true, true, true);
    emit KickedBatch(members, sharesBurned, lootBurned);
    shaman.kick(members);

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), 0);
    assertEq(sharesToken.balanceOf(wearer2), 0);
    assertEq(lootToken.balanceOf(wearer2), 0);
  }

  function test_batch_offboarded_inBadStanding_canBeKicked() public {
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    vm.prank(wearer2);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer2), startingShares);

    // they are both placed in bad standing for the hat
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, false);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));
    assertFalse(HATS.isInGoodStanding(wearer1, memberHat));
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer2, false, false);
    assertFalse(HATS.isWearerOfHat(wearer2, memberHat));
    assertFalse(HATS.isInGoodStanding(wearer2, memberHat));

    // they are both offboarded
    members = new address[](2);
    members[0] = wearer1;
    members[1] = wearer2;
    shaman.offboard(members);

    // they can both be kicked
    sharesBurned = new uint256[](2);
    lootBurned = new uint256[](2);
    sharesBurned[0] = 0;
    sharesBurned[1] = 0;
    lootBurned[0] = startingShares;
    lootBurned[1] = startingShares;
    vm.expectEmit(true, true, true, true);
    emit KickedBatch(members, sharesBurned, lootBurned);
    shaman.kick(members);

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), 0);
    assertEq(sharesToken.balanceOf(wearer2), 0);
    assertEq(lootToken.balanceOf(wearer2), 0);
  }

  function test_batch_sharesAndLoot_inBadStanding_canBeKicked() public {
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    vm.prank(wearer2);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer2), startingShares);

    // they are both placed in bad standing for the hat
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, false);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));
    assertFalse(HATS.isInGoodStanding(wearer1, memberHat));
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer2, false, false);
    assertFalse(HATS.isWearerOfHat(wearer2, memberHat));
    assertFalse(HATS.isInGoodStanding(wearer2, memberHat));

    // they are both offboarded
    members = new address[](2);
    members[0] = wearer1;
    members[1] = wearer2;
    shaman.offboard(members);

    // somehow they both earn more shares
    grantShares(wearer1, startingShares / 2);
    grantShares(wearer2, startingShares / 3);

    // they can both be kicked
    sharesBurned = new uint256[](2);
    lootBurned = new uint256[](2);
    sharesBurned[0] = startingShares / 2;
    sharesBurned[1] = startingShares / 3;
    lootBurned[0] = startingShares;
    lootBurned[1] = startingShares;
    vm.expectEmit(true, true, true, true);
    emit KickedBatch(members, sharesBurned, lootBurned);
    shaman.kick(members);

    assertEq(sharesToken.balanceOf(wearer1), 0);
    assertEq(lootToken.balanceOf(wearer1), 0);
    assertEq(sharesToken.balanceOf(wearer2), 0);
    assertEq(lootToken.balanceOf(wearer2), 0);
  }

  function test_batch_inGoodStanding_reverts() public {
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    vm.prank(wearer2);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer2), startingShares);

    // one is in good standing for the hat
    assertTrue(HATS.isInGoodStanding(wearer1, memberHat));
    // one is in bad sanding
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer2, false, false);
    assertFalse(HATS.isWearerOfHat(wearer2, memberHat));

    // they cannot be kicked
    members = new address[](2);
    members[0] = wearer1;
    members[1] = wearer2;
    vm.expectRevert(abi.encodeWithSelector(NotInBadStanding.selector, wearer1));
    shaman.kick(members);

    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    assertEq(lootToken.balanceOf(wearer1), 0);
    assertEq(sharesToken.balanceOf(wearer2), startingShares);
    assertEq(lootToken.balanceOf(wearer2), 0);
  }

  function test_batch_nonMember_reverts() public {
    // one is onboarded
    vm.prank(wearer1);
    shaman.onboard();
    assertEq(sharesToken.balanceOf(wearer1), startingShares);

    // both are is in bad sanding for the hat
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer1, false, false);
    assertFalse(HATS.isWearerOfHat(wearer1, memberHat));
    vm.prank(eligibility);
    HATS.setHatWearerStatus(memberHat, wearer2, false, false);
    assertFalse(HATS.isWearerOfHat(wearer2, memberHat));

    // they cannot be kicked
    members = new address[](2);
    members[0] = wearer1;
    members[1] = wearer2;
    vm.expectRevert(abi.encodeWithSelector(NotMember.selector, wearer2));
    shaman.kick(members);

    assertEq(sharesToken.balanceOf(wearer1), startingShares);
    assertEq(lootToken.balanceOf(wearer1), 0);
    assertEq(sharesToken.balanceOf(wearer2), 0);
    assertEq(lootToken.balanceOf(wearer2), 0);
  }
}

contract SetStartingShares is WithInstanceTest {
  uint256 public newStartingShares;

  function test_owner_canSetStartingShares() public {
    newStartingShares = startingShares + 1;

    vm.prank(dao);
    vm.expectEmit(true, true, true, true);
    emit StartingSharesSet(newStartingShares);
    shaman.setStartingShares(newStartingShares);

    assertEq(shaman.startingShares(), newStartingShares);
  }

  function test_nonOwner_reverts() public {
    newStartingShares = startingShares + 1;

    vm.prank(nonWearer);
    vm.expectRevert(NotOwner.selector);
    shaman.setStartingShares(newStartingShares);

    assertEq(shaman.startingShares(), startingShares);
  }
}

contract SetRoleStakingShaman is WithInstanceTest {
// TODO
}

// TODO test with HatsRoleStakingShaman
