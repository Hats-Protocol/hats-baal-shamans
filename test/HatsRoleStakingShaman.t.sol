// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test, console2 } from "forge-std/Test.sol";
import { HatsRoleStakingShaman, LibClone } from "../src/HatsRoleStakingShaman.sol";
import { IRoleStakingShaman } from "../src/interfaces/IRoleStakingShaman.sol";
import { StakingProxy } from "../src/StakingProxy.sol";
import { DeployImplementation } from "../script/HatsRoleStakingShaman.s.sol";
import {
  IHats,
  HatsModuleFactory,
  deployModuleFactory,
  deployModuleInstance
} from "lib/hats-module/src/utils/DeployFunctions.sol";
import { IBaal } from "baal/interfaces/IBaal.sol";
import { IBaalToken } from "baal/interfaces/IBaalToken.sol";
import { IBaalSummoner } from "baal/interfaces/IBaalSummoner.sol";

contract HatsRoleStakingShamanTest is DeployImplementation, Test {
  // variables inherited from DeployImplementation script
  // HatsRoleStakingShaman public implementation;
  // bytes32 public SALT;

  uint256 public fork;
  uint256 public BLOCK_NUMBER = 16_947_805; // the block number where v1.hatsprotocol.eth was deployed;

  IHats public constant HATS = IHats(0x9D2dfd6066d5935267291718E8AA16C8Ab729E9d); // v1.hatsprotocol.eth
  string public FACTORY_VERSION = "factory test version";
  string public SHAMAN_VERSION = "shaman test version";

  event MinStakeSet(uint256 _hat, uint112 _minStake);
  event Slashed(address member, uint256 hat, uint112 amount);
  event Staked(address member, uint256 hat, uint112 amount);
  event UnstakeBegun(address member, uint256 hat, uint112 amount);
  event UnstakeCompleted(address member, uint256 hat, uint112 amount);

  error RoleAlreadyRegistered();
  error InvalidRole();
  error InvalidMinStake();
  error RoleStillRegistered();
  error NotEligible();
  error CooldownNotEnded();
  error InsufficientStake();
  error NotInBadStanding();
  error NotRoleManager();
  error NotJudge();
  error NotHatAdmin();
  error HatImmutable();

  function setUp() public virtual {
    // create and activate a fork, at BLOCK_NUMBER
    fork = vm.createSelectFork(vm.rpcUrl("mainnet"), BLOCK_NUMBER);

    // deploy via the script
    DeployImplementation.prepare(SHAMAN_VERSION, false); // set last arg to true to log deployment addresses
    DeployImplementation.run();
  }
}

contract WithInstanceTest is HatsRoleStakingShamanTest {
  HatsModuleFactory public factory;
  HatsRoleStakingShaman public shaman;
  uint256 public hatId;
  bytes public otherImmutableArgs;
  bytes public initData;

  uint32 public cooldownBuffer;

  address public zodiacFactory = 0x00000000000DC7F163742Eb4aBEf650037b1f588;
  IBaalSummoner public summoner = IBaalSummoner(0x7e988A9db2F8597735fc68D21060Daed948a3e8C);
  IBaal public baal;
  IBaalToken public sharesToken;

  StakingProxy public stakingProxyImplementation;
  StakingProxy public stakingProxy;

  uint256 public baalSaltNonce;

  address[] public members;
  uint256[] public sharesBurned;

  // hat properties
  uint112 public minStake = 1000;
  string public details;
  string public image;
  bool public mut; // mutable
  uint32 public maxSupply;

  uint112 public stake;
  uint112 public unstakeAmount;
  uint112 public retStakedAmount;
  uint112 public retUnstakingAmount;
  uint112 public retCanUnstakeAfter;

  uint256 public tophat;
  uint256 public shamanHat;
  uint256 public roleManagerHat;
  uint256 public judgeHat;
  uint256 public role1Hat;
  uint256 public role2Hat;
  address public eligibility = makeAddr("eligibility");
  address public toggle = makeAddr("toggle");
  address public dao; // will be set to the baal address
  address public judge = makeAddr("judge");
  address public roleManager = makeAddr("roleManager");

  address public member1 = makeAddr("member1");
  address public member2 = makeAddr("member2");
  address public member3 = makeAddr("member3");

  address public nonWearer = makeAddr("nonWearer");

  address public predictedBaalAddress;
  address public predictedShamanAddress;

  function deployInstance(
    address _baal,
    uint256 _shamanHat,
    address _stakingProxyImplementation,
    uint256 _roleManagerHat,
    uint256 _judgeHat,
    uint32 _cooldownBuffer
  ) public returns (HatsRoleStakingShaman) {
    // encode the other immutable args as packed bytes
    otherImmutableArgs = abi.encodePacked(_baal, _stakingProxyImplementation, _roleManagerHat, _judgeHat);
    // encoded the initData as unpacked bytes -- for HatsRoleStakingShaman, we just need any non-empty bytes
    initData = abi.encode(_cooldownBuffer);
    // deploy the instance
    return HatsRoleStakingShaman(
      deployModuleInstance(factory, address(implementation), _shamanHat, otherImmutableArgs, initData)
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

  function addRole(uint112 _minStake, bool _mutable) public returns (uint256) {
    vm.prank(roleManager);
    return shaman.createRole("role1Hat", 1, address(shaman), toggle, _mutable, "dao.eth/role1Hat", _minStake);
  }

  function predictStakingProxyAddress(address _member) public view returns (address) {
    bytes memory args = abi.encodePacked(address(shaman), address(shaman.SHARES_TOKEN()), _member);
    return LibClone.predictDeterministicAddress(shaman.STAKING_PROXY_IMPL(), args, keccak256(args), address(shaman));
  }

  function setUp() public virtual override {
    super.setUp();
    cooldownBuffer = 1 days;

    // deploy the staking proxy implementation
    stakingProxyImplementation = new StakingProxy();

    // deploy the hats module factory
    factory = deployModuleFactory(HATS, SALT, FACTORY_VERSION);

    // predict the baal's address
    predictedBaalAddress = predictBaalAddress(SALT);
    dao = predictedBaalAddress;

    // set up hats
    tophat = HATS.mintTopHat(dao, "tophat", "dao.eth/tophat");
    vm.startPrank(dao);
    shamanHat = HATS.createHat(tophat, "shamanHat", 1, eligibility, toggle, true, "dao.eth/shamanHat");
    roleManagerHat = HATS.createHat(tophat, "roleManagerHat", 1, eligibility, toggle, true, "dao.eth/roleManagerHat");
    judgeHat = HATS.createHat(tophat, "judgeHat", 1, eligibility, toggle, true, "dao.eth/judgeHat");
    HATS.mintHat(roleManagerHat, roleManager);
    HATS.mintHat(judgeHat, judge);
    vm.stopPrank();

    // predict the shaman's address via the hats module factory
    predictedShamanAddress = factory.getHatsModuleAddress(
      address(implementation),
      shamanHat,
      abi.encodePacked(predictedBaalAddress, address(stakingProxyImplementation), roleManagerHat, judgeHat)
    );

    // deploy a test baal with the predicted shaman address
    baal = deployBaalWithShaman("TEST_BAAL", "TEST_BAAL", SALT, predictedShamanAddress);

    // find and set baal token addresses
    sharesToken = IBaalToken(baal.sharesToken());

    // deploy the shaman instance
    shaman = deployInstance(
      predictedBaalAddress, shamanHat, address(stakingProxyImplementation), roleManagerHat, judgeHat, cooldownBuffer
    );

    // ensure that the actual and predicted addresses are the same
    require(address(baal) == predictedBaalAddress, "actual and predicted baal addresses do not match");

    // mint shaman hat to shaman
    vm.prank(dao);
    HATS.mintHat(shamanHat, address(shaman));
  }
}

contract Deployment is WithInstanceTest {
  function test_setAsManagerShaman() public {
    assertEq(baal.shamans(address(shaman)), 2);
  }

  function test_version() public {
    assertEq(shaman.version(), SHAMAN_VERSION);
  }

  function test_cooldownBuffer() public {
    assertEq(shaman.cooldownBuffer(), cooldownBuffer);
  }

  function test_baal() public {
    assertEq(address(shaman.BAAL()), address(baal));
    assertEq(address(shaman.BAAL()), predictBaalAddress(SALT));
  }

  function test_sharesToken() public {
    assertEq(address(shaman.SHARES_TOKEN()), address(sharesToken));
  }

  function test_roleManagerHat() public {
    assertEq(shaman.ROLE_MANAGER_HAT(), roleManagerHat);
  }

  function test_judgeHat() public {
    assertEq(shaman.JUDGE_HAT(), judgeHat);
  }

  function test_stakingProxyImplementation() public {
    assertEq(address(shaman.STAKING_PROXY_IMPL()), address(stakingProxyImplementation));
  }
}

contract CreatingRoles is WithInstanceTest {
  function setUp() public override {
    super.setUp();
    mut = true;
    maxSupply = 1;
  }

  function test_createRole_roleManager_canCreate() public {
    role1Hat = HATS.buildHatId(shamanHat, 1);

    details = "role1";
    image = "dao.eth/role1";

    vm.prank(roleManager);

    vm.expectEmit(true, true, true, true);
    emit MinStakeSet(role1Hat, minStake);
    shaman.createRole(details, maxSupply, eligibility, toggle, mut, image, minStake);

    assertEq(shaman.minStakes(role1Hat), minStake);
  }

  function test_createRole_nonRoleManager_reverts() public {
    details = "role1";
    image = "dao.eth/role1";
    vm.prank(nonWearer);
    vm.expectRevert(NotRoleManager.selector);
    shaman.createRole(details, maxSupply, eligibility, toggle, mut, image, minStake);
  }

  function test_createSubRole_roleManager_canCreate() public {
    role1Hat = HATS.buildHatId(shamanHat, 1);
    role2Hat = HATS.buildHatId(role1Hat, 1);

    details = "role2";
    image = "dao.eth/role2";

    vm.prank(roleManager);

    vm.expectEmit(true, true, true, true);
    emit MinStakeSet(role2Hat, minStake);
    shaman.createSubRole(role1Hat, details, maxSupply, eligibility, toggle, mut, image, minStake);

    assertEq(shaman.minStakes(role2Hat), minStake);
  }

  function test_createSubRole_nonRoleManager_reverts() public {
    role1Hat = HATS.buildHatId(shamanHat, 1);
    details = "role2";
    image = "dao.eth/role2";

    vm.prank(nonWearer);
    vm.expectRevert(NotRoleManager.selector);
    shaman.createSubRole(role1Hat, details, maxSupply, eligibility, toggle, mut, image, minStake);
  }
}

contract RegisteringRoles is WithInstanceTest {
  function test_happy() public {
    // create a mutable hat
    vm.prank(dao);
    role1Hat = HATS.createHat(shamanHat, "role1Hat", 1, eligibility, toggle, true, "dao.eth/role1Hat");

    // min stake is valid
    minStake = 1000;

    vm.prank(roleManager);
    vm.expectEmit(true, true, true, true);
    emit MinStakeSet(role1Hat, minStake);
    shaman.registerRole(role1Hat, minStake);

    assertEq(shaman.minStakes(role1Hat), minStake);
  }

  function test_nonRoleManager_reverts() public {
    // create a mutable hat
    vm.prank(dao);
    role1Hat = HATS.createHat(shamanHat, "role1Hat", 1, eligibility, toggle, true, "dao.eth/role1Hat");

    // min stake is valid
    minStake = 1000;

    vm.prank(nonWearer);
    vm.expectRevert(NotRoleManager.selector);
    shaman.registerRole(role1Hat, minStake);

    assertEq(shaman.minStakes(role1Hat), 0);
  }

  function test_immutableHat_reverts() public {
    // create an immutable hat
    vm.prank(dao);
    role1Hat = HATS.createHat(shamanHat, "role1Hat", 1, eligibility, toggle, false, "dao.eth/role1Hat");

    // min stake is valid
    minStake = 1000;

    vm.prank(roleManager);
    vm.expectRevert(HatImmutable.selector);
    shaman.registerRole(role1Hat, minStake);

    assertEq(shaman.minStakes(role1Hat), 0);
  }

  function test_invalidRole_reverts() public {
    // create a new child of the tophat
    vm.prank(dao);
    uint256 otherHat = HATS.createHat(tophat, "not in shaman branch", 1, eligibility, toggle, true, "dao.eth/other");

    // min stake is valid
    minStake = 1000;

    vm.prank(roleManager);
    vm.expectRevert(InvalidRole.selector);
    // attempt to add the tophat
    shaman.registerRole(otherHat, minStake);

    assertEq(shaman.minStakes(otherHat), 0);
  }

  function test_roleAlreadyRegistered_reverts() public {
    // create a mutable hat
    vm.prank(dao);
    role1Hat = HATS.createHat(shamanHat, "role1Hat", 1, eligibility, toggle, true, "dao.eth/role1Hat");

    // min stake is valid
    minStake = 1000;

    vm.prank(roleManager);
    vm.expectEmit(true, true, true, true);
    emit MinStakeSet(role1Hat, minStake);
    shaman.registerRole(role1Hat, minStake);

    assertEq(shaman.minStakes(role1Hat), minStake);

    // attempt to register again
    vm.prank(roleManager);
    vm.expectRevert(RoleAlreadyRegistered.selector);
    shaman.registerRole(role1Hat, minStake * 2);

    assertEq(shaman.minStakes(role1Hat), minStake);
  }
}

contract DeregisteringRoles is WithInstanceTest {
  function setUp() public override {
    super.setUp();
    minStake = 1000;
    mut = true;
    maxSupply = 1;
  }

  function test_happy() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    vm.prank(roleManager);
    vm.expectEmit(true, true, true, true);
    emit MinStakeSet(role1Hat, 0);
    shaman.deregisterRole(role1Hat);

    assertEq(shaman.minStakes(role1Hat), 0);
  }

  function test_nonRoleManager_reverts() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    vm.prank(nonWearer);
    vm.expectRevert(NotRoleManager.selector);
    shaman.deregisterRole(role1Hat);

    assertEq(shaman.minStakes(role1Hat), minStake);
  }

  function test_immutableHat_reverts() public {
    // create and register an immutable role
    role1Hat = addRole(minStake, false);

    vm.prank(roleManager);
    vm.expectRevert(HatImmutable.selector);
    shaman.deregisterRole(role1Hat);

    assertEq(shaman.minStakes(role1Hat), minStake);
  }
}

contract SettingMinStake is WithInstanceTest {
  uint112 public newMinStake;

  function setUp() public override {
    super.setUp();
    minStake = 1000;
    mut = true;
    maxSupply = 1;
  }

  function test_happy() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // set a new min stake
    newMinStake = minStake * 2;

    vm.prank(roleManager);
    vm.expectEmit(true, true, true, true);
    emit MinStakeSet(role1Hat, newMinStake);
    shaman.setMinStake(role1Hat, newMinStake);

    assertEq(shaman.minStakes(role1Hat), newMinStake);
  }

  function test_invalidRole_reverts() public {
    // create a new child of the tophat
    vm.prank(dao);
    uint256 otherHat = HATS.createHat(tophat, "not in shaman branch", 1, eligibility, toggle, true, "dao.eth/other");

    vm.prank(roleManager);
    vm.expectRevert(InvalidRole.selector);
    shaman.setMinStake(otherHat, minStake);

    assertEq(shaman.minStakes(otherHat), 0);
  }

  function test_nonRoleManager_reverts() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // set a new min stake
    newMinStake = minStake * 2;

    vm.prank(nonWearer);
    vm.expectRevert(NotRoleManager.selector);
    shaman.setMinStake(role1Hat, newMinStake);

    assertEq(shaman.minStakes(role1Hat), minStake);
  }

  function test_immutableHat_reverts() public {
    // create and register an immutable role
    role1Hat = addRole(minStake, false);

    // set a new min stake
    newMinStake = minStake * 2;

    vm.prank(roleManager);
    vm.expectRevert(HatImmutable.selector);
    shaman.setMinStake(role1Hat, newMinStake);

    assertEq(shaman.minStakes(role1Hat), minStake);
  }
}

contract Staking is WithInstanceTest {
  function setUp() public override {
    super.setUp();
  }

  function test_firstStake_happy() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    stake = 5000;

    // give member1 some shares
    grantShares(member1, stake);

    // member1 stakes, delegating to self
    vm.prank(member1);
    vm.expectEmit(true, true, true, true);
    emit Staked(member1, role1Hat, stake);
    shaman.stakeOnRole(role1Hat, stake, member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);

    assertEq(retStakedAmount, stake);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_invalidRole_reverts() public {
    // create a new child of the tophat
    vm.prank(dao);
    uint256 otherHat = HATS.createHat(tophat, "not in shaman branch", 1, eligibility, toggle, true, "dao.eth/other");

    stake = 5000;

    // give member1 some shares
    grantShares(member1, stake);

    vm.prank(member1);
    vm.expectRevert(InvalidRole.selector);
    shaman.stakeOnRole(otherHat, stake, member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(otherHat, member1);

    assertEq(retStakedAmount, 0);
    assertEq(shaman.memberStakes(member1), 0);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_insufficientShares_reverts() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    stake = 5000;

    // give member1 too few shares
    grantShares(member1, stake - 1);

    // member1 stakes, delegating to self
    vm.prank(member1);
    vm.expectRevert();
    shaman.stakeOnRole(role1Hat, stake, member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);

    assertEq(retStakedAmount, 0);
    assertEq(shaman.memberStakes(member1), 0);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake - 1);
  }

  function test_delegateToOther_succeeds() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    stake = 5000;

    // give member1 some shares
    grantShares(member1, stake);

    // member1 stakes, delegating to other address
    vm.prank(member1);
    vm.expectEmit(true, true, true, true);
    emit Staked(member1, role1Hat, stake);
    shaman.stakeOnRole(role1Hat, stake, nonWearer);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);

    assertEq(retStakedAmount, stake);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 0);
    assertEq(shaman.SHARES_TOKEN().getVotes(nonWearer), stake);
  }

  function test_secondStake_happy() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    stake = 5000;

    // give member1 some shares
    grantShares(member1, stake);

    // member1 stakes, delegating to self
    vm.prank(member1);
    vm.expectEmit(true, true, true, true);
    emit Staked(member1, role1Hat, stake);
    shaman.stakeOnRole(role1Hat, stake, member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);

    assertEq(retStakedAmount, stake);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);

    // give member1 some more shares
    grantShares(member1, stake + 500);

    // member1 stakes again, delegating to self
    vm.prank(member1);
    vm.expectEmit(true, true, true, true);
    emit Staked(member1, role1Hat, stake);
    shaman.stakeOnRole(role1Hat, stake, member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);

    assertEq(retStakedAmount, stake * 2);
    assertEq(shaman.memberStakes(member1), stake * 2);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake * 2 + 500);
  }
}

contract Claiming is WithInstanceTest {
  function test_stakingEligibility_happy() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);
    // set stake value
    stake = minStake;
    // give member1 some shares
    grantShares(member1, stake);
    // member1 stakes enough shares
    vm.prank(member1);
    shaman.stakeOnRole(role1Hat, stake, member1);

    // member1 claims
    vm.prank(member1);
    shaman.claimRole(role1Hat);

    assertTrue(HATS.isWearerOfHat(member1, role1Hat));
  }

  function test_otherEligibility_happy() public {
    // create and register a mutable role with a different eligibility module
    vm.prank(dao);
    role1Hat = HATS.createHat(shamanHat, "role1", 1, eligibility, toggle, true, "dao.eth/role1");
    vm.prank(roleManager);
    shaman.registerRole(role1Hat, minStake);

    // set stake value
    stake = minStake;
    // give member1 some shares
    grantShares(member1, stake);
    // member1 stakes enough shares
    vm.prank(member1);
    shaman.stakeOnRole(role1Hat, stake, member1);

    // role1's eligibility module is not the staking shaman
    assertFalse(HATS.getHatEligibilityModule(role1Hat) == address(shaman));
    // mock the explicit eligibility call to return true
    vm.mockCall(
      eligibility,
      abi.encodeWithSelector(HatsRoleStakingShaman.getWearerStatus.selector, member1, role1Hat),
      (abi.encode(true, true))
    );

    // member1 claims
    vm.prank(member1);
    shaman.claimRole(role1Hat);

    assertTrue(HATS.isWearerOfHat(member1, role1Hat));
  }

  function test_invalidRole_reverts() public {
    // create a new child of the tophat
    vm.prank(dao);
    uint256 otherHat = HATS.createHat(tophat, "not in shaman branch", 1, eligibility, toggle, true, "dao.eth/other");

    // member1 claims
    vm.prank(member1);
    vm.expectRevert(InvalidRole.selector);
    shaman.claimRole(otherHat);

    assertFalse(HATS.isWearerOfHat(member1, otherHat));
  }

  function test_insufficientStake_reverts() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);
    // set stake value to less than minStake
    stake = minStake - 1;
    // give member1 some shares
    grantShares(member1, stake);
    // member1 stakes not enough shares
    vm.prank(member1);
    shaman.stakeOnRole(role1Hat, stake, member1);
    assertEq(shaman.memberStakes(member1), stake);

    // role1's eligibility module is the staking shaman
    assertEq(HATS.getHatEligibilityModule(role1Hat), address(shaman));

    // member1 attempts to claim
    vm.prank(member1);
    vm.expectRevert(InsufficientStake.selector);
    shaman.claimRole(role1Hat);

    assertFalse(HATS.isWearerOfHat(member1, role1Hat));
  }

  function test_notExplicitlyEligible_reverts() public {
    // create and register a mutable role with a different eligibility module
    vm.prank(dao);
    role1Hat = HATS.createHat(shamanHat, "role1", 1, eligibility, toggle, true, "dao.eth/role1");
    vm.prank(roleManager);
    shaman.registerRole(role1Hat, minStake);

    // set stake value
    stake = minStake;
    // give member1 some shares
    grantShares(member1, stake);
    // member1 stakes enough shares
    vm.prank(member1);
    shaman.stakeOnRole(role1Hat, stake, member1);

    // role1's eligibility module is not the staking shaman
    assertFalse(HATS.getHatEligibilityModule(role1Hat) == address(shaman));
    // by default the eligibility module will say the member is not eligible

    // member1 attempts to claim
    vm.prank(member1);
    vm.expectRevert(NotEligible.selector);
    shaman.claimRole(role1Hat);

    assertFalse(HATS.isWearerOfHat(member1, role1Hat));
  }
}

contract StakingAndClaiming is WithInstanceTest {
  function test_stakingEligibility_happy() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);
    // set stake value
    stake = minStake;
    // give member1 some shares
    grantShares(member1, stake);
    // member1 stakes enough shares
    vm.prank(member1);
    vm.expectEmit(true, true, true, true);
    emit Staked(member1, role1Hat, stake);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    assertTrue(HATS.isWearerOfHat(member1, role1Hat));
  }

  function test_otherEligibility_happy() public {
    // create and register a mutable role with a different eligibility module
    vm.prank(dao);
    role1Hat = HATS.createHat(shamanHat, "role1", 1, eligibility, toggle, true, "dao.eth/role1");
    vm.prank(roleManager);
    shaman.registerRole(role1Hat, minStake);

    // set stake value
    stake = minStake;
    // give member1 some shares
    grantShares(member1, stake);

    // role1's eligibility module is not the staking shaman
    assertFalse(HATS.getHatEligibilityModule(role1Hat) == address(shaman));
    // mock the explicit eligibility call to return true
    vm.mockCall(
      eligibility,
      abi.encodeWithSelector(HatsRoleStakingShaman.getWearerStatus.selector, member1, role1Hat),
      (abi.encode(true, true))
    );

    // member1 stakes and claims, with enough shares
    vm.prank(member1);
    vm.expectEmit(true, true, true, true);
    emit Staked(member1, role1Hat, stake);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    assertTrue(HATS.isWearerOfHat(member1, role1Hat));
  }

  function test_invalidRole_reverts() public {
    // create a new child of the tophat
    vm.prank(dao);
    uint256 otherHat = HATS.createHat(tophat, "not in shaman branch", 1, eligibility, toggle, true, "dao.eth/other");

    // set stake value
    stake = minStake;
    // give member1 some shares
    grantShares(member1, stake);

    // member1 attempts to stake and claim, with enough shares
    vm.prank(member1);
    vm.expectRevert(InvalidRole.selector);
    shaman.stakeAndClaimRole(otherHat, stake, member1);

    assertFalse(HATS.isWearerOfHat(member1, otherHat));
  }

  function test_insufficientStake_reverts() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);
    // set stake value to less than minStake
    stake = minStake - 1;
    // give member1 some shares
    grantShares(member1, stake);

    // member1 attempts to stake and claim with not enough shares
    vm.prank(member1);
    vm.expectRevert(InsufficientStake.selector);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    assertFalse(HATS.isWearerOfHat(member1, role1Hat));
  }

  function test_notExplicitlyEligible_reverts() public {
    // create and register a mutable role with a different eligibility module
    vm.prank(dao);
    role1Hat = HATS.createHat(shamanHat, "role1", 1, eligibility, toggle, true, "dao.eth/role1");
    vm.prank(roleManager);
    shaman.registerRole(role1Hat, minStake);

    // role1's eligibility module is not the staking shaman
    assertFalse(HATS.getHatEligibilityModule(role1Hat) == address(shaman));
    // by default the eligibility module will say the member is not eligible

    // set stake value
    stake = minStake;
    // give member1 some shares
    grantShares(member1, stake);

    // member1 attempts to stake and claim with enough shares, but is not eligible
    vm.prank(member1);
    vm.expectRevert(NotEligible.selector);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    assertFalse(HATS.isWearerOfHat(member1, role1Hat));
  }

  function test_delegateToOther_succeeds() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);
    // set stake value
    stake = minStake;
    // give member1 some shares
    grantShares(member1, stake);
    // member1 stakes enough shares
    vm.prank(member1);
    vm.expectEmit(true, true, true, true);
    emit Staked(member1, role1Hat, stake);
    shaman.stakeAndClaimRole(role1Hat, stake, nonWearer);

    assertTrue(HATS.isWearerOfHat(member1, role1Hat));

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);

    assertEq(retStakedAmount, stake);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(nonWearer), stake);
  }
}

contract SettingStanding is WithInstanceTest {
  function test_happy() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // judge sets member1's standing to false
    vm.prank(judge);
    shaman.setStanding(role1Hat, member1, false);

    (bool eligible, bool standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, false);
    assertEq(standing, false);

    // judge resets member1's standing to true
    vm.prank(judge);
    shaman.setStanding(role1Hat, member1, true);

    (eligible, standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, false);
    assertEq(standing, true);
  }

  function test_nonJudge_reverts() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // nonWearer attempts to set member1's standing
    vm.prank(nonWearer);
    vm.expectRevert(NotJudge.selector);
    shaman.setStanding(role1Hat, member1, false);

    (bool eligible, bool standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, false);
    assertEq(standing, true);
  }

  function test_invalidRole_reverts() public {
    // create a new child of the tophat
    vm.prank(dao);
    uint256 otherHat = HATS.createHat(tophat, "not in shaman branch", 1, eligibility, toggle, true, "dao.eth/other");
    assertTrue(shaman.minStakes(otherHat) == 0);

    // judge attempts to set member1's standing
    vm.prank(judge);
    vm.expectRevert(InvalidRole.selector);
    shaman.setStanding(otherHat, member1, false);

    (bool eligible, bool standing) = shaman.getWearerStatus(member1, otherHat);
    assertEq(eligible, true); // true since there is no minStake
    assertEq(standing, true);
  }
}

contract GettingWearerStatus is WithInstanceTest {
  function test_true_forUnegisteredRoles() public {
    // create and register a mutable role with a different eligibility module
    vm.prank(dao);
    role1Hat = HATS.createHat(shamanHat, "role1", 1, eligibility, toggle, true, "dao.eth/role1");

    // role1's eligibility module is not the staking shaman
    assertFalse(HATS.getHatEligibilityModule(role1Hat) == address(shaman));

    (bool eligible, bool standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, true); // true since there is no minStake
    assertEq(standing, true);
  }

  function test_false_whenBadStanding() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // not yet eligible
    (bool eligible, bool standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, false);
    assertEq(standing, true);

    // member1 stakes and claims enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    // now member1 is eligible
    (eligible, standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, true);
    assertEq(standing, true);

    // judge sets member1's standing to false
    vm.prank(judge);
    shaman.setStanding(role1Hat, member1, false);

    // now member1 is not eligible since they are in bad standing
    (eligible, standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, false); // false since standing is false
    assertEq(standing, false);
  }

  function test_true_sufficientStake() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // not yet eligible
    (bool eligible, bool standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, false);
    assertEq(standing, true);

    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    // now member1 is eligible
    (eligible, standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, true);
    assertEq(standing, true);
  }
}

contract Slashing is WithInstanceTest {
  function test_happy() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);

    assertEq(retStakedAmount, stake);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);

    // judge places member1 in bad standing
    vm.prank(judge);
    shaman.setStanding(role1Hat, member1, false);
    // they lose the hat
    assertFalse(HATS.isWearerOfHat(member1, role1Hat));

    // anybody can now slash member1's stake for roleHat1
    vm.prank(nonWearer);
    vm.expectEmit(true, true, true, true);
    emit Slashed(member1, role1Hat, stake);
    shaman.slash(member1, role1Hat);

    // member1's stake is now 0
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);

    assertEq(retStakedAmount, 0);
    assertEq(retUnstakingAmount, 0);
    assertEq(shaman.memberStakes(member1), 0);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 0);
  }

  function test_invalidRole_stakingEligibility_reverts() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    // judge places member1 in bad standing
    vm.prank(judge);
    shaman.setStanding(role1Hat, member1, false);

    // role is deregistered
    vm.prank(roleManager);
    shaman.deregisterRole(role1Hat);

    // attempts to slash will fail
    vm.prank(nonWearer);
    vm.expectRevert(InvalidRole.selector);
    shaman.slash(member1, role1Hat);

    // member1's stake is unchanged
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    assertEq(retStakedAmount, stake);
    assertEq(retUnstakingAmount, 0);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_invalidRole_otherEligibility_reverts() public {
    // create and register a mutable role with a different eligibility module
    vm.prank(dao);
    role1Hat = HATS.createHat(shamanHat, "role1", 1, eligibility, toggle, true, "dao.eth/role1");
    vm.prank(roleManager);
    shaman.registerRole(role1Hat, minStake);

    // member1 stakes w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeOnRole(role1Hat, stake, member1);

    // role is deregistered
    vm.prank(roleManager);
    shaman.deregisterRole(role1Hat);

    // member1 gets placed in bad standing in the other eligibility module
    vm.prank(eligibility);
    HATS.setHatWearerStatus(role1Hat, member1, false, false);

    // attempts to slash will fail even though member1 is in bad standing
    vm.prank(nonWearer);
    vm.expectRevert(InvalidRole.selector);
    shaman.slash(member1, role1Hat);

    // member1's stake is unchanged
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    assertEq(retStakedAmount, stake);
    assertEq(retUnstakingAmount, 0);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_notInBadStanding_stakingEligibility_reverts() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    // attempts to slash will fail
    vm.prank(nonWearer);
    vm.expectRevert(NotInBadStanding.selector);
    shaman.slash(member1, role1Hat);

    // member1's stake is unchanged
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    assertEq(retStakedAmount, stake);
    assertEq(retUnstakingAmount, 0);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_notInBadStanding_otherEligibility_reverts() public {
    // create and register a mutable role with a different eligibility module
    vm.prank(dao);
    role1Hat = HATS.createHat(shamanHat, "role1", 1, eligibility, toggle, true, "dao.eth/role1");
    vm.prank(roleManager);
    shaman.registerRole(role1Hat, minStake);

    // member1 stakes w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeOnRole(role1Hat, stake, member1);

    // attempts to slash will fail
    vm.prank(nonWearer);
    vm.expectRevert(NotInBadStanding.selector);
    shaman.slash(member1, role1Hat);

    // member1's stake is unchanged
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    assertEq(retStakedAmount, stake);
    assertEq(retUnstakingAmount, 0);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_inCooldown_succeeds() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    // member1 begins unstaking
    unstakeAmount = stake / 3;
    vm.prank(member1);
    shaman.beginUnstakeFromRole(role1Hat, unstakeAmount);

    // judge places member1 in bad standing
    vm.prank(judge);
    shaman.setStanding(role1Hat, member1, false);

    // member1's stake is slashed
    vm.prank(nonWearer);
    vm.expectEmit(true, true, true, true);
    emit Slashed(member1, role1Hat, stake);
    shaman.slash(member1, role1Hat);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    assertEq(retStakedAmount, 0, "roleStake");
    assertEq(retUnstakingAmount, 0, "unstaking");
    assertEq(retCanUnstakeAfter, 0, "cooldown ends");
    assertEq(shaman.memberStakes(member1), 0, "member stake");
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 0, "votes");
  }
}

contract BeginUnstaking is WithInstanceTest {
  function test_happy() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    // member1 begins unstaking
    unstakeAmount = stake / 3;
    vm.prank(member1);
    vm.expectEmit(true, true, true, true);
    emit UnstakeBegun(member1, role1Hat, unstakeAmount);
    shaman.beginUnstakeFromRole(role1Hat, unstakeAmount);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    assertEq(retStakedAmount, stake - unstakeAmount);
    assertEq(retUnstakingAmount, unstakeAmount);
    assertEq(retCanUnstakeAfter, block.timestamp + shaman.cooldownPeriod());
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_inBadStanding_slashes() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    // member is placed in bad standing
    vm.prank(judge);
    shaman.setStanding(role1Hat, member1, false);

    // member1 begins unstaking, but is slashed instead
    vm.prank(member1);
    vm.expectEmit(true, true, true, true);
    emit Slashed(member1, role1Hat, stake);
    shaman.beginUnstakeFromRole(role1Hat, stake);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    assertEq(retStakedAmount, 0);
    assertEq(retUnstakingAmount, 0);
    assertEq(retCanUnstakeAfter, 0);
    assertEq(shaman.memberStakes(member1), 0);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 0);
  }

  function test_insufficientStake_reverts() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    // member1 begins unstaking more than they have staked
    unstakeAmount = stake + 1;
    vm.prank(member1);
    vm.expectRevert(InsufficientStake.selector);
    shaman.beginUnstakeFromRole(role1Hat, unstakeAmount);

    // member 1 stake data unchanged since they lost some shares
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    assertEq(retStakedAmount, stake);
    assertEq(retUnstakingAmount, 0);
    assertEq(retCanUnstakeAfter, 0);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_cooldownNotEnded_reverts() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    // member1 begins unstaking a little bit
    unstakeAmount = stake / 3;
    vm.prank(member1);
    shaman.beginUnstakeFromRole(role1Hat, unstakeAmount);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    uint256 expCanUnstakeAfter = block.timestamp + shaman.cooldownPeriod();
    uint112 expStakedAmount = uint112(stake - unstakeAmount);
    assertEq(retStakedAmount, expStakedAmount);
    assertEq(retUnstakingAmount, unstakeAmount);
    assertEq(retCanUnstakeAfter, expCanUnstakeAfter);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);

    // member1 tries to begin unstaking again before cooldown is over
    vm.warp(expCanUnstakeAfter - 1);
    unstakeAmount = stake / 4;
    vm.prank(member1);
    vm.expectRevert(CooldownNotEnded.selector);
    shaman.beginUnstakeFromRole(role1Hat, unstakeAmount);

    // member 1 stake data unchanged
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    assertEq(retStakedAmount, expStakedAmount, "roleStake");
    assertEq(retUnstakingAmount, stake / 3, "unstaking");
    assertEq(retCanUnstakeAfter, expCanUnstakeAfter, "cooldown ends");
    assertEq(shaman.memberStakes(member1), stake, "member stake");
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake, "votes");
  }

  function test_insufficientStakeInProxy_reverts() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    // somehow member1 loses some of their stake (eg a different shaman burns shares from their proxy)
    members = new address[](1);
    members[0] = predictStakingProxyAddress(member1);
    sharesBurned = new uint256[](1);
    sharesBurned[0] = 2 * stake / 3;
    vm.prank(address(shaman));
    baal.burnShares(members, sharesBurned);

    // member1 begins unstaking more than they have left
    unstakeAmount = stake / 2;
    vm.prank(member1);
    vm.expectRevert(InsufficientStake.selector);
    shaman.beginUnstakeFromRole(role1Hat, unstakeAmount);

    // member 1 stake data unchanged since they lost some shares
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    assertEq(retStakedAmount, stake, "roleStake");
    assertEq(retUnstakingAmount, 0, "unstaking");
    assertEq(retCanUnstakeAfter, 0, "cooldown ends");
    assertEq(shaman.memberStakes(member1), stake, "member stake");
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake - sharesBurned[0], "votes");
  }
}

contract CompleteUnstaking is WithInstanceTest {
  function test_happy() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    // member1 begins unstaking
    unstakeAmount = stake / 3;
    vm.prank(member1);
    vm.expectEmit(true, true, true, true);
    emit UnstakeBegun(member1, role1Hat, unstakeAmount);
    shaman.beginUnstakeFromRole(role1Hat, unstakeAmount);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    uint256 cooldownEnds = block.timestamp + shaman.cooldownPeriod();
    assertEq(retStakedAmount, stake - unstakeAmount);
    assertEq(retUnstakingAmount, unstakeAmount);
    assertEq(retCanUnstakeAfter, block.timestamp + shaman.cooldownPeriod());
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);

    // warp ahead to cooldown end
    vm.warp(cooldownEnds + 1);

    // member1 completes unstaking
    vm.expectEmit(true, true, true, true);
    emit UnstakeCompleted(member1, role1Hat, unstakeAmount);
    shaman.completeUnstakeFromRole(role1Hat, member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    assertEq(retStakedAmount, stake - unstakeAmount);
    assertEq(retUnstakingAmount, 0);
    assertEq(retCanUnstakeAfter, 0);
    assertEq(shaman.memberStakes(member1), stake - unstakeAmount);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_inBadStanding_slashes() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    // member1 begins unstaking
    unstakeAmount = stake / 3;
    vm.prank(member1);
    vm.expectEmit(true, true, true, true);
    emit UnstakeBegun(member1, role1Hat, unstakeAmount);
    shaman.beginUnstakeFromRole(role1Hat, unstakeAmount);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    uint256 cooldownEnds = block.timestamp + shaman.cooldownPeriod();
    assertEq(retStakedAmount, stake - unstakeAmount);
    assertEq(retUnstakingAmount, unstakeAmount);
    assertEq(retCanUnstakeAfter, block.timestamp + shaman.cooldownPeriod());
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);

    // member is placed in bad standing
    vm.prank(judge);
    shaman.setStanding(role1Hat, member1, false);

    // warp ahead to cooldown end
    vm.warp(cooldownEnds + 1);

    // member1 completes unstaking, but is slashed
    vm.expectEmit(true, true, true, true);
    emit Slashed(member1, role1Hat, stake);
    shaman.completeUnstakeFromRole(role1Hat, member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    assertEq(retStakedAmount, 0);
    assertEq(retUnstakingAmount, 0);
    assertEq(retCanUnstakeAfter, 0);
    assertEq(shaman.memberStakes(member1), 0);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 0);
  }

  function test_cooldownNotEnded_reverts() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    // member1 begins unstaking
    unstakeAmount = stake / 3;
    vm.prank(member1);
    vm.expectEmit(true, true, true, true);
    emit UnstakeBegun(member1, role1Hat, unstakeAmount);
    shaman.beginUnstakeFromRole(role1Hat, unstakeAmount);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    uint256 cooldownEnds = block.timestamp + shaman.cooldownPeriod();
    assertEq(retStakedAmount, stake - unstakeAmount);
    assertEq(retUnstakingAmount, unstakeAmount);
    assertEq(retCanUnstakeAfter, block.timestamp + shaman.cooldownPeriod());
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);

    // warp ahead to just before cooldown end
    vm.warp(cooldownEnds - 1);

    // member1 attempts to complete unstaking
    vm.expectRevert(CooldownNotEnded.selector);
    shaman.completeUnstakeFromRole(role1Hat, member1);

    // member1's stake data is unchanged
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    assertEq(retStakedAmount, stake - unstakeAmount);
    assertEq(retUnstakingAmount, unstakeAmount);
    assertEq(retCanUnstakeAfter, cooldownEnds);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_insufficientStakeInProxy_reverts() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    // member1 begins unstaking
    unstakeAmount = stake - 200;
    vm.prank(member1);
    vm.expectEmit(true, true, true, true);
    emit UnstakeBegun(member1, role1Hat, unstakeAmount);
    shaman.beginUnstakeFromRole(role1Hat, unstakeAmount);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    uint256 cooldownEnds = block.timestamp + shaman.cooldownPeriod();
    assertEq(retStakedAmount, 200);
    assertEq(retUnstakingAmount, 800);
    assertEq(retCanUnstakeAfter, block.timestamp + shaman.cooldownPeriod());
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);

    // somehow member1 loses some of their stake (eg a different shaman burns shares from their proxy)
    members = new address[](1);
    members[0] = predictStakingProxyAddress(member1);
    sharesBurned = new uint256[](1);
    sharesBurned[0] = 400;
    vm.prank(address(shaman));
    baal.burnShares(members, sharesBurned);

    // warp ahead to cooldown end
    vm.warp(cooldownEnds);

    // member1 completes unstaking
    vm.expectRevert(InsufficientStake.selector);
    shaman.completeUnstakeFromRole(role1Hat, member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    assertEq(retStakedAmount, 200);
    assertEq(retUnstakingAmount, 800);
    assertEq(retCanUnstakeAfter, cooldownEnds);
    assertEq(shaman.memberStakes(member1), 1000);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 600);
  }
}

contract UnstakingFromDeregisteredRole is WithInstanceTest {
  function test_happy() public {
    // create and register a mutable role
    role1Hat = addRole(minStake, true);

    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaimRole(role1Hat, stake, member1);

    // role is deregistered
    vm.prank(roleManager);
    shaman.deregisterRole(role1Hat);

    // member1 can unstake with no cooldown
    vm.prank(member1);
    vm.expectEmit(true, true, true, true);
    emit UnstakeCompleted(member1, role1Hat, stake);
    shaman.unstakeFromDeregisteredRole(role1Hat);

    // member1's stake is updated
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.roleStakes(role1Hat, member1);
    assertEq(retStakedAmount, 0);
    assertEq(retUnstakingAmount, 0);
    assertEq(shaman.memberStakes(member1), 0);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_roleStillRegistered_reverts() public { }

  function test_insufficientStake_reverts() public { }

  function test_inBadStanding_slashes() public { }

  function test_inCooldown_succeeds() public { }
}
