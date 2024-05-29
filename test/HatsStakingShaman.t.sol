// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test, console2 } from "forge-std/Test.sol";
import { HatsStakingShaman, LibClone } from "../src/HatsStakingShaman.sol";
import { IRoleStakingShaman } from "../src/interfaces/IRoleStakingShaman.sol";
import {
  MultiClaimsHatter,
  MultiClaimsHatter_NotExplicitlyEligible
} from "../lib/multi-claims-hatter/src/MultiClaimsHatter.sol";
import { StakingProxy } from "../src/StakingProxy.sol";
import { DeployImplementation } from "../script/HatsStakingShaman.s.sol";
import {
  IHats,
  HatsModuleFactory,
  deployModuleFactory,
  deployModuleInstance
} from "lib/hats-module/src/utils/DeployFunctions.sol";
import { IBaal } from "baal/interfaces/IBaal.sol";
import { IBaalToken } from "baal/interfaces/IBaalToken.sol";
import { IBaalSummoner } from "baal/interfaces/IBaalSummoner.sol";

contract HatsStakingShamanTest is DeployImplementation, Test {
  // variables inherited from DeployImplementation script
  // HatsStakingShaman public implementation;
  // bytes32 public SALT;

  uint256 public fork;
  uint256 public BLOCK_NUMBER = 19_970_940; // the block number where the HatsModuleFactory was deployed;

  IHats public constant HATS = IHats(0x3bc1A0Ad72417f2d411118085256fC53CBdDd137); // v1.hatsprotocol.eth
  HatsModuleFactory public constant FACTORY = HatsModuleFactory(0x0a3f85fa597B6a967271286aA0724811acDF5CD9);
  string public FACTORY_VERSION = "factory test version";
  string public SHAMAN_VERSION = "shaman test version";
  uint256 public constant SALT_NONCE = 1;

  event MinStakeSet(uint112 minStake);
  event Slashed(address member, uint112 amount);
  event Staked(address member, uint112 amount);
  event UnstakeBegun(address member, uint112 amount);
  event UnstakeCompleted(address member, uint112 amount);
  event JudgeSet(uint256 judge);

  error InvalidMinStake();
  error RoleStillRegistered();
  error CooldownNotEnded();
  error InsufficientStake();
  error NotInBadStanding();
  error NotJudge();
  error HatImmutable();
  error NotAdmin();
  error NotShaman();

  function setUp() public virtual {
    // create and activate a fork, at BLOCK_NUMBER
    fork = vm.createSelectFork(vm.rpcUrl("mainnet"), BLOCK_NUMBER);

    // deploy via the script
    DeployImplementation.prepare(SHAMAN_VERSION, false); // set last arg to true to log deployment addresses
    DeployImplementation.run();
  }
}

contract WithInstanceTest is HatsStakingShamanTest {
  HatsStakingShaman public shaman;
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
  uint256 public autoAdmin;
  uint256 public judgeHat;
  uint256 public roleAdminHat;
  uint256 public role1Hat;
  address public eligibility = makeAddr("eligibility");
  address public toggle = makeAddr("toggle");
  address public dao; // will be set to the baal safe address
  address public roleAdmin = makeAddr("roleAdmin");
  address public judge = makeAddr("judge");

  address public member1 = makeAddr("member1");
  address public member2 = makeAddr("member2");
  address public member3 = makeAddr("member3");

  address public nonWearer = makeAddr("nonWearer");

  address public predictedBaalAddress;
  address public predictedShamanAddress;

  function deployInstance(
    address _baal,
    uint256 _roleHat,
    address _stakingProxyImplementation,
    uint256 _judgeHat,
    uint32 _cooldownBuffer,
    uint112 _minStake
  ) public returns (HatsStakingShaman) {
    // encode the other immutable args as packed bytes
    otherImmutableArgs = abi.encodePacked(_baal, _stakingProxyImplementation);
    // encoded the initData as unpacked bytes
    initData = abi.encode(_cooldownBuffer, _judgeHat, _minStake);

    // deploy the instance
    return HatsStakingShaman(
      deployModuleInstance(FACTORY, address(implementation), _roleHat, otherImmutableArgs, initData, SALT_NONCE)
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

  function setShaman(address _shaman, uint256 _permission) public {
    address[] memory shamans = new address[](1);
    uint256[] memory permissions = new uint256[](1);
    shamans[0] = _shaman;
    permissions[0] = _permission;
    vm.prank(dao);
    baal.setShamans(shamans, permissions);
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

  function predictStakingProxyAddress(address _member) public view returns (address) {
    bytes memory args = abi.encodePacked(address(shaman), address(shaman.SHARES_TOKEN()), _member);
    return LibClone.predictDeterministicAddress(shaman.STAKING_PROXY_IMPL(), args, keccak256(args), address(shaman));
  }

  function setUp() public virtual override {
    super.setUp();
    cooldownBuffer = 1 days;

    // deploy the staking proxy implementation
    stakingProxyImplementation = new StakingProxy();

    // predict the baal's address
    predictedBaalAddress = predictBaalAddress(SALT);

    // set up hats
    // start with the tophat worn by a random address; we'll transfer it to the dao later once we know the dao's address
    address temp = makeAddr("temp");
    tophat = HATS.mintTopHat(temp, "tophat", "dao.eth/tophat");
    vm.startPrank(temp);
    autoAdmin = HATS.createHat(tophat, "autoAdmin", 1, eligibility, toggle, true, "dao.eth/autoAdmin");
    judgeHat = HATS.createHat(autoAdmin, "judgeHat", 1, eligibility, toggle, true, "dao.eth/judgeHat");
    roleAdminHat = HATS.createHat(autoAdmin, "roleAdminHat", 1, eligibility, toggle, true, "dao.eth/roleAdminHat");
    role1Hat = HATS.createHat(roleAdminHat, "role1Hat", 1, eligibility, toggle, true, "dao.eth/role1Hat");
    HATS.mintHat(judgeHat, judge);
    HATS.mintHat(roleAdminHat, roleAdmin);
    vm.stopPrank();

    // predict the shaman's address via the hats module factory
    predictedShamanAddress = FACTORY.getHatsModuleAddress(
      address(implementation),
      role1Hat,
      abi.encodePacked(predictedBaalAddress, address(stakingProxyImplementation)),
      SALT_NONCE
    );

    // deploy a test baal with the predicted shaman address
    baal = deployBaalWithShaman("TEST_BAAL", "TEST_BAAL", SALT, predictedShamanAddress);

    // set the dao as the baal's safe
    dao = baal.avatar();

    vm.prank(temp);
    HATS.transferHat(tophat, temp, dao);

    // set the shaman as the role1Hat eligibility
    vm.prank(roleAdmin);
    HATS.changeHatEligibility(role1Hat, predictedShamanAddress);

    // ensure that the actual and predicted addresses are the same
    assertEq(address(baal), predictedBaalAddress, "SETUP: actual and predicted baal addresses do not match");

    // find and set baal token addresses
    sharesToken = IBaalToken(baal.sharesToken());

    // deploy the shaman instance
    shaman = deployInstance(
      predictedBaalAddress, role1Hat, address(stakingProxyImplementation), judgeHat, cooldownBuffer, minStake
    );

    assertEq(address(shaman), predictedShamanAddress, "SETUP: actual and predicted shaman addresses do not match");
  }
}

contract Deployment is WithInstanceTest {
  function test_setAsManagerShaman() public view {
    assertEq(baal.shamans(address(shaman)), 2);
  }

  function test_version() public view {
    assertEq(shaman.version(), SHAMAN_VERSION);
  }

  function test_cooldownBuffer() public view {
    assertEq(shaman.cooldownBuffer(), cooldownBuffer);
  }

  function test_baal() public view {
    assertEq(address(shaman.BAAL()), address(baal));
    assertEq(address(shaman.BAAL()), predictBaalAddress(SALT));
  }

  function test_sharesToken() public view {
    assertEq(address(shaman.SHARES_TOKEN()), address(sharesToken));
  }

  function test_judgeHat() public view {
    assertEq(shaman.judge(), judgeHat);
  }

  function test_minStake() public view {
    assertEq(shaman.minStake(), minStake);
  }

  function test_stakingProxyImplementation() public view {
    assertEq(address(shaman.STAKING_PROXY_IMPL()), address(stakingProxyImplementation));
  }

  function test_initialized() public {
    bytes memory testInitData = abi.encode(12_456);
    // implementation
    vm.expectRevert();
    implementation.setUp(testInitData);
    // instance
    vm.expectRevert();
    shaman.setUp(testInitData);
  }
}

contract SettingMinStake is WithInstanceTest {
  uint112 public newMinStake;

  function setUp() public override {
    super.setUp();
    minStake = 1000;
  }

  function test_happy() public {
    assertEq(shaman.minStake(), minStake);

    // set a new min stake
    newMinStake = minStake * 2;
    vm.prank(roleAdmin);
    vm.expectEmit();
    emit MinStakeSet(newMinStake);
    shaman.setMinStake(newMinStake);

    assertEq(shaman.minStake(), newMinStake);
  }

  function test_revert_nonRoleAdmin() public {
    // set a new min stake
    newMinStake = minStake * 2;

    vm.prank(nonWearer);
    vm.expectRevert(NotAdmin.selector);
    shaman.setMinStake(newMinStake);

    assertEq(shaman.minStake(), minStake);
  }

  function test_revert_immutableHat() public {
    // make role1Hat immutable
    vm.prank(roleAdmin);
    HATS.makeHatImmutable(role1Hat);

    // set a new min stake
    newMinStake = minStake * 2;

    vm.prank(roleAdmin);
    vm.expectRevert(HatImmutable.selector);
    shaman.setMinStake(newMinStake);

    assertEq(shaman.minStake(), minStake);
  }
}

contract Staking is WithInstanceTest {
  function setUp() public override {
    super.setUp();
  }

  function test_firstStake_happy() public {
    stake = 5000;

    // give member1 some shares
    grantShares(member1, stake);

    // member1 stakes, delegating to self
    vm.prank(member1);
    vm.expectEmit();
    emit Staked(member1, stake);
    shaman.stake(stake, member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);

    assertEq(retStakedAmount, stake);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_secondStake_happy() public {
    stake = 5000;

    // give member1 some shares
    grantShares(member1, stake);

    // member1 stakes, delegating to self
    vm.prank(member1);
    vm.expectEmit();
    emit Staked(member1, stake);
    shaman.stake(stake, member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);

    assertEq(retStakedAmount, stake);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);

    // give member1 some more shares
    grantShares(member1, stake + 500);

    // member1 stakes again, delegating to self
    vm.prank(member1);
    vm.expectEmit();
    emit Staked(member1, stake);
    shaman.stake(stake, member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);

    assertEq(retStakedAmount, stake * 2);
    assertEq(shaman.memberStakes(member1), stake * 2);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake * 2 + 500);
  }

  function test_revert_notShaman() public {
    stake = 5000;

    // give member1 some shares
    grantShares(member1, stake);

    // disable shaman from dao
    setShaman(address(shaman), 0);

    // now staking should be disallowed
    vm.prank(member1);
    vm.expectRevert(abi.encodeWithSelector(HatsStakingShaman.NotShaman.selector));
    shaman.stake(stake, member1);

    assertEq(shaman.memberStakes(member1), 0);
  }

  function test_revert_insufficientShares() public {
    stake = 5000;

    // give member1 too few shares
    grantShares(member1, stake - 1);

    // member1 stakes, delegating to self
    vm.prank(member1);
    vm.expectRevert();
    shaman.stake(stake, member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);

    assertEq(retStakedAmount, 0);
    assertEq(shaman.memberStakes(member1), 0);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake - 1);
  }

  function test_delegateToOther_succeeds() public {
    stake = 5000;

    // give member1 some shares
    grantShares(member1, stake);

    // member1 stakes, delegating to other address
    vm.prank(member1);
    vm.expectEmit();
    emit Staked(member1, stake);
    shaman.stake(stake, nonWearer);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);

    assertEq(retStakedAmount, stake);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 0);
    assertEq(shaman.SHARES_TOKEN().getVotes(nonWearer), stake);
  }
}

contract WithClaimsHatter is WithInstanceTest {
  address public claimsHatterImplementation = 0xBf931B514DECA60Fd386dEC2DCBd42650c7417d9;
  MultiClaimsHatter public claimsHatter;

  function setUp() public virtual override {
    super.setUp();

    // deploy a new claims hatter
    claimsHatter = MultiClaimsHatter(deployModuleInstance(FACTORY, claimsHatterImplementation, 0, "", "", SALT_NONCE));

    // mint it to the autoAdmin hat
    assertTrue(HATS.isAdminOfHat(dao, autoAdmin), "not admin");
    vm.prank(dao);
    HATS.mintHat(autoAdmin, address(claimsHatter));
  }

  function _makeClaimableFor(uint256 hat) internal {
    vm.prank(dao);
    claimsHatter.setHatClaimability(hat, MultiClaimsHatter.ClaimType.ClaimableFor);
  }
}

contract Claiming is WithClaimsHatter {
  function test_claim_happy() public {
    // set stake value
    stake = minStake;
    // give member1 some shares
    grantShares(member1, stake);
    // member1 stakes enough shares
    vm.prank(member1);
    shaman.stake(stake, member1);

    // dao makes role1Hat claimable
    _makeClaimableFor(role1Hat);

    // member1 claims
    vm.prank(member1);
    shaman.claim(claimsHatter);

    assertTrue(HATS.isWearerOfHat(member1, role1Hat));
  }

  function test_revert_insufficientStake() public {
    // set stake value to less than minStake
    stake = minStake - 1;
    // give member1 some shares
    grantShares(member1, stake);
    // member1 stakes not enough shares
    vm.prank(member1);
    shaman.stake(stake, member1);
    assertEq(shaman.memberStakes(member1), stake);

    // role1's eligibility module is the staking shaman
    assertEq(HATS.getHatEligibilityModule(role1Hat), address(shaman));

    // dao makes role1Hat claimable
    _makeClaimableFor(role1Hat);

    // member1 attempts to claim
    vm.prank(member1);
    vm.expectRevert(abi.encodeWithSelector(MultiClaimsHatter_NotExplicitlyEligible.selector, member1, role1Hat));
    shaman.claim(claimsHatter);

    assertFalse(HATS.isWearerOfHat(member1, role1Hat));
  }
}

contract StakingAndClaiming is WithClaimsHatter {
  function test_stakeAndClaim_happy() public {
    // set stake value
    stake = minStake;
    // give member1 some shares
    grantShares(member1, stake);
    // dao makes role1Hat claimable
    _makeClaimableFor(role1Hat);
    // member1 stakes enough shares
    vm.prank(member1);
    vm.expectEmit();
    emit Staked(member1, stake);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    assertTrue(HATS.isWearerOfHat(member1, role1Hat));
  }

  function test_revert_insufficientStake() public {
    // set stake value to less than minStake
    stake = minStake - 1;
    // give member1 some shares
    grantShares(member1, stake);
    // dao makes role1Hat claimable
    _makeClaimableFor(role1Hat);

    // member1 attempts to stake and claim with not enough shares
    vm.prank(member1);
    vm.expectRevert(abi.encodeWithSelector(MultiClaimsHatter_NotExplicitlyEligible.selector, member1, role1Hat));
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    assertFalse(HATS.isWearerOfHat(member1, role1Hat));
  }

  function test_delegateToOther_succeeds() public {
    // set stake value
    stake = minStake;
    // give member1 some shares
    grantShares(member1, stake);
    // dao makes role1Hat claimable
    _makeClaimableFor(role1Hat);
    // member1 stakes enough shares and delegates to nonWearer
    vm.prank(member1);
    vm.expectEmit();
    emit Staked(member1, stake);
    shaman.stakeAndClaim(stake, nonWearer, claimsHatter);

    assertTrue(HATS.isWearerOfHat(member1, role1Hat));

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);

    assertEq(retStakedAmount, stake);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(nonWearer), stake);
  }
}

contract SettingStanding is WithInstanceTest {
  function test_happy() public {
    // judge sets member1's standing to false
    vm.prank(judge);
    shaman.setStanding(member1, false);

    (bool eligible, bool standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, false);
    assertEq(standing, false);

    // judge resets member1's standing to true
    vm.prank(judge);
    shaman.setStanding(member1, true);

    (eligible, standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, false);
    assertEq(standing, true);
  }

  function test_revert_nonJudge() public {
    // nonWearer attempts to set member1's standing
    vm.prank(nonWearer);
    vm.expectRevert(NotJudge.selector);
    shaman.setStanding(member1, false);

    (bool eligible, bool standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, false);
    assertEq(standing, true);
  }
}

contract GettingWearerStatus is WithInstanceTest {
  function test_false_whenBadStanding() public {
    // not yet eligible
    (bool eligible, bool standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, false);
    assertEq(standing, true);

    // member1 stakes with enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stake(stake, member1);

    // now member1 is eligible
    (eligible, standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, true);
    assertEq(standing, true);

    // judge sets member1's standing to false
    vm.prank(judge);
    shaman.setStanding(member1, false);

    // now member1 is not eligible since they are in bad standing
    (eligible, standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, false); // false since standing is false
    assertEq(standing, false);
  }

  function test_true_sufficientStake() public {
    // not yet eligible
    (bool eligible, bool standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, false);
    assertEq(standing, true);

    // member1 stakes enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stake(stake, member1);

    // now member1 is eligible
    (eligible, standing) = shaman.getWearerStatus(member1, role1Hat);
    assertEq(eligible, true);
    assertEq(standing, true);
  }

  function test_false_insufficientStake() public {
    // set stake value to less than minStake
    stake = minStake - 1;
    // give member1 some shares
    grantShares(member1, stake);

    // member1 stakes not enough shares
    vm.prank(member1);
    shaman.stake(stake, member1);
  }
}

contract Slashing is WithClaimsHatter {
  function setUp() public virtual override {
    super.setUp();
    // dao makes role1hat claimable for
    _makeClaimableFor(role1Hat);
  }

  function test_slash_happy() public {
    // dao
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);

    assertEq(retStakedAmount, stake);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);

    // judge places member1 in bad standing
    vm.prank(judge);
    shaman.setStanding(member1, false);
    // they lose the hat
    assertFalse(HATS.isWearerOfHat(member1, role1Hat));

    // anybody can now slash member1's stake for roleHat1
    vm.prank(nonWearer);
    vm.expectEmit();
    emit Slashed(member1, stake);
    shaman.slash(member1);

    // member1's stake is now 0
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);

    assertEq(retStakedAmount, 0);
    assertEq(retUnstakingAmount, 0);
    assertEq(shaman.memberStakes(member1), 0);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 0);
  }

  function test_revert_notInBadStanding() public {
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    // attempts to slash will fail
    vm.prank(nonWearer);
    vm.expectRevert(NotInBadStanding.selector);
    shaman.slash(member1);

    // member1's stake is unchanged
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, stake);
    assertEq(retUnstakingAmount, 0);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_inCooldown_succeeds() public {
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    // member1 begins unstaking
    unstakeAmount = stake / 3;
    vm.prank(member1);
    shaman.beginUnstake(unstakeAmount);

    // judge places member1 in bad standing
    vm.prank(judge);
    shaman.setStanding(member1, false);

    // member1's full stake is slashed
    vm.prank(nonWearer);
    vm.expectEmit();
    emit Slashed(member1, stake);
    shaman.slash(member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, 0, "roleStake");
    assertEq(retUnstakingAmount, 0, "unstaking");
    assertEq(retCanUnstakeAfter, 0, "cooldown ends");
    assertEq(shaman.memberStakes(member1), 0, "member stake");
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 0, "votes");
  }
}

contract BeginUnstaking is WithClaimsHatter {
  function setUp() public virtual override {
    super.setUp();
    // dao makes role1hat claimable for
    _makeClaimableFor(role1Hat);
  }

  function test_happy() public {
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    // member1 begins unstaking
    unstakeAmount = stake / 3;
    vm.prank(member1);
    vm.expectEmit();
    emit UnstakeBegun(member1, unstakeAmount);
    shaman.beginUnstake(unstakeAmount);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, stake - unstakeAmount);
    assertEq(retUnstakingAmount, unstakeAmount);
    assertEq(retCanUnstakeAfter, block.timestamp + shaman.cooldownPeriod());
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_inBadStanding_slashes() public {
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    // member is placed in bad standing
    vm.prank(judge);
    shaman.setStanding(member1, false);

    // member1 begins unstaking, but is slashed instead
    vm.prank(member1);
    vm.expectEmit();
    emit Slashed(member1, stake);
    shaman.beginUnstake(unstakeAmount);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, 0);
    assertEq(retUnstakingAmount, 0);
    assertEq(retCanUnstakeAfter, 0);
    assertEq(shaman.memberStakes(member1), 0);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 0);
  }

  function test_revert_insufficientStake() public {
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    // member1 begins unstaking more than they have staked
    unstakeAmount = stake + 1;
    vm.prank(member1);
    vm.expectRevert(InsufficientStake.selector);
    shaman.beginUnstake(unstakeAmount);

    // member 1 stake data unchanged since they lost some shares
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, stake);
    assertEq(retUnstakingAmount, 0);
    assertEq(retCanUnstakeAfter, 0);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_revert_cooldownNotEnded() public {
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    // member1 begins unstaking a little bit
    unstakeAmount = stake / 3;
    vm.prank(member1);
    shaman.beginUnstake(unstakeAmount);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
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
    shaman.beginUnstake(unstakeAmount);

    // member 1 stake data unchanged
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, expStakedAmount, "roleStake");
    assertEq(retUnstakingAmount, stake / 3, "unstaking");
    assertEq(retCanUnstakeAfter, expCanUnstakeAfter, "cooldown ends");
    assertEq(shaman.memberStakes(member1), stake, "member stake");
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake, "votes");
  }

  function test_revert_insufficientStakeInProxy() public {
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

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
    shaman.beginUnstake(unstakeAmount);

    // member 1 stake data unchanged since they lost some shares
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, stake, "roleStake");
    assertEq(retUnstakingAmount, 0, "unstaking");
    assertEq(retCanUnstakeAfter, 0, "cooldown ends");
    assertEq(shaman.memberStakes(member1), stake - sharesBurned[0], "member stake");
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake - sharesBurned[0], "votes");
  }
}

contract CompleteUnstaking is WithClaimsHatter {
  function setUp() public virtual override {
    super.setUp();
    // dao makes role1hat claimable for
    _makeClaimableFor(role1Hat);
  }

  function test_happy() public {
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    // member1 begins unstaking
    unstakeAmount = stake / 3;
    vm.prank(member1);
    vm.expectEmit();
    emit UnstakeBegun(member1, unstakeAmount);
    shaman.beginUnstake(unstakeAmount);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    uint256 cooldownEnds = block.timestamp + shaman.cooldownPeriod();
    assertEq(retStakedAmount, stake - unstakeAmount);
    assertEq(retUnstakingAmount, unstakeAmount);
    assertEq(retCanUnstakeAfter, block.timestamp + shaman.cooldownPeriod());
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);

    // warp ahead to cooldown end
    vm.warp(cooldownEnds + 1);

    // member1 completes unstaking
    vm.expectEmit();
    emit UnstakeCompleted(member1, unstakeAmount);
    shaman.completeUnstake(member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, stake - unstakeAmount);
    assertEq(retUnstakingAmount, 0);
    assertEq(retCanUnstakeAfter, 0);
    assertEq(shaman.memberStakes(member1), stake - unstakeAmount);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_inBadStanding_slashes() public {
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    // member1 begins unstaking
    unstakeAmount = stake / 3;
    vm.prank(member1);
    vm.expectEmit();
    emit UnstakeBegun(member1, unstakeAmount);
    shaman.beginUnstake(unstakeAmount);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    uint256 cooldownEnds = block.timestamp + shaman.cooldownPeriod();
    assertEq(retStakedAmount, stake - unstakeAmount);
    assertEq(retUnstakingAmount, unstakeAmount);
    assertEq(retCanUnstakeAfter, block.timestamp + shaman.cooldownPeriod());
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);

    // member is placed in bad standing
    vm.prank(judge);
    shaman.setStanding(member1, false);

    // warp ahead to cooldown end
    vm.warp(cooldownEnds + 1);

    // member1 completes unstaking, but is slashed
    vm.expectEmit();
    emit Slashed(member1, stake);
    shaman.completeUnstake(member1);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, 0);
    assertEq(retUnstakingAmount, 0);
    assertEq(retCanUnstakeAfter, 0);
    assertEq(shaman.memberStakes(member1), 0);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 0);
  }

  function test_revert_cooldownNotEnded() public {
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    // member1 begins unstaking
    unstakeAmount = stake / 3;
    vm.prank(member1);
    vm.expectEmit();
    emit UnstakeBegun(member1, unstakeAmount);
    shaman.beginUnstake(unstakeAmount);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
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
    shaman.completeUnstake(member1);

    // member1's stake data is unchanged
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, stake - unstakeAmount);
    assertEq(retUnstakingAmount, unstakeAmount);
    assertEq(retCanUnstakeAfter, cooldownEnds);
    assertEq(shaman.memberStakes(member1), stake);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_revert_insufficientStakeInProxy() public {
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    // member1 begins unstaking
    unstakeAmount = stake - 200;
    vm.prank(member1);
    vm.expectEmit();
    emit UnstakeBegun(member1, unstakeAmount);
    shaman.beginUnstake(unstakeAmount);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    uint256 cooldownEnds = block.timestamp + shaman.cooldownPeriod();
    assertEq(retStakedAmount, 200, "roleStake");
    assertEq(retUnstakingAmount, 800, "unstaking");
    assertEq(retCanUnstakeAfter, block.timestamp + shaman.cooldownPeriod(), "cooldown ends");
    assertEq(shaman.memberStakes(member1), stake, "member stake");
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake, "votes");

    // somehow member1 loses some of their stake (eg a different shaman burns shares from their proxy)
    members = new address[](1);
    members[0] = predictStakingProxyAddress(member1);
    sharesBurned = new uint256[](1);
    sharesBurned[0] = 400;
    vm.prank(address(shaman));
    baal.burnShares(members, sharesBurned);

    // warp ahead to cooldown end
    vm.warp(cooldownEnds);

    // member1 attempts to complete unstaking
    vm.expectRevert(InsufficientStake.selector);
    shaman.completeUnstake(member1);

    // but can't because they don't have enough stake in their proxy
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, 200, "roleStake");
    assertEq(retUnstakingAmount, 800, "unstaking");
    assertEq(retCanUnstakeAfter, cooldownEnds, "cooldown ends");
    assertEq(shaman.memberStakes(member1), 600, "member stake");
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 600, "votes");
  }

  function test_resetUnstake_succeeds() public {
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    // member1 begins unstaking a smaller amount
    unstakeAmount = stake - 200;
    vm.prank(member1);
    vm.expectEmit();
    emit UnstakeBegun(member1, unstakeAmount);
    shaman.beginUnstake(unstakeAmount);

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    uint256 cooldownEnds = block.timestamp + shaman.cooldownPeriod();
    assertEq(retStakedAmount, 200, "roleStake");
    assertEq(retUnstakingAmount, 800, "unstaking");
    assertEq(retCanUnstakeAfter, block.timestamp + shaman.cooldownPeriod(), "cooldown ends");
    assertEq(shaman.memberStakes(member1), stake, "member stake");
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake, "votes");

    // somehow member1 loses some of their stake (eg a different shaman burns shares from their proxy)
    // more shares are burned than what member1 would have left in their proxy after unstaking
    members = new address[](1);
    members[0] = predictStakingProxyAddress(member1);
    sharesBurned = new uint256[](1);
    sharesBurned[0] = 400;
    vm.prank(address(shaman));
    baal.burnShares(members, sharesBurned);

    // warp ahead to cooldown end
    vm.warp(cooldownEnds);

    // member1 attempts to complete unstaking
    vm.expectRevert(InsufficientStake.selector);
    shaman.completeUnstake(member1);

    // but can't because they don't have enough stake in their proxy
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, 200, "roleStake");
    assertEq(retUnstakingAmount, 800, "unstaking");
    assertEq(retCanUnstakeAfter, cooldownEnds, "cooldown ends");
    assertEq(shaman.memberStakes(member1), 600, "member stake");
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 600, "votes");

    // now member1 resets their unstake to a lower amount, below what they have in their proxy
    unstakeAmount = 599;
    vm.prank(member1);
    vm.expectEmit();
    emit UnstakeBegun(member1, unstakeAmount);
    shaman.resetUnstake(unstakeAmount);

    // member1's stake data is updated
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    cooldownEnds = block.timestamp + shaman.cooldownPeriod();
    assertEq(retStakedAmount, 401, "roleStake");
    assertEq(retUnstakingAmount, 599, "unstaking");
    assertEq(retCanUnstakeAfter, cooldownEnds, "cooldown ends");
    assertEq(shaman.memberStakes(member1), 600, "member stake");
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 600, "votes");

    // warp ahead to new cooldown end
    vm.warp(cooldownEnds);

    // now member1 can complete unstake, since they have sufficient stake in their proxy
    vm.expectEmit();
    emit UnstakeCompleted(member1, unstakeAmount);
    shaman.completeUnstake(member1);

    // member1's stake data is updated accordingly
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, 401, "roleStake");
    assertEq(retUnstakingAmount, 0, "unstaking");
    assertEq(retCanUnstakeAfter, 0, "cooldown ends");
    assertEq(shaman.memberStakes(member1), 1, "member stake");
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 600, "votes");
  }
}

contract UnstakingFromDeregisteredRole is WithClaimsHatter {
  function setUp() public virtual override {
    super.setUp();
    // dao makes role1hat claimable for
    _makeClaimableFor(role1Hat);
  }

  function test_happy() public {
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    // role1 is deregistered by changing the eligibility module
    vm.prank(roleAdmin);
    HATS.changeHatEligibility(role1Hat, eligibility);

    // member1 can unstake with no cooldown
    vm.prank(member1);
    vm.expectEmit();
    emit UnstakeCompleted(member1, stake);
    shaman.unstakeFromDeregisteredRole();

    // member1's stake is updated
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, 0);
    assertEq(retUnstakingAmount, 0);
    assertEq(shaman.memberStakes(member1), 0);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake);
  }

  function test_withStakeRemoved() public {
    // member1 stakes and claims both w/ enough shares
    stake = minStake;
    grantShares(member1, stake * 3);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    // role1 is deregistered by changing the eligibility module
    vm.prank(roleAdmin);
    HATS.changeHatEligibility(role1Hat, eligibility);

    // somehow member1 loses their stake amount (eg a different shaman burns shares from their proxy)
    members = new address[](1);
    members[0] = predictStakingProxyAddress(member1);
    sharesBurned = new uint256[](1);
    sharesBurned[0] = stake;
    vm.prank(address(shaman));
    baal.burnShares(members, sharesBurned);

    // member1 can unstake with no cooldown
    uint112 remainingStake = stake - uint112(sharesBurned[0]);
    vm.prank(member1);
    vm.expectEmit();
    emit UnstakeCompleted(member1, remainingStake);
    shaman.unstakeFromDeregisteredRole();

    // member1's stake is updated for role1...
    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, 0, "role1 stake");
    assertEq(retUnstakingAmount, 0, "role1 unstaking");
    assertEq(shaman.memberStakes(member1), remainingStake, "member1 stakes");
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), stake * 2, "member 1votes");
  }

  function test_revert_roleStillRegistered() public {
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    // member1 can't unstake from a role that's still registered
    vm.prank(member1);
    vm.expectRevert(RoleStillRegistered.selector);
    shaman.unstakeFromDeregisteredRole();
  }

  function test_inBadStanding_slashes() public {
    // member1 stakes and claims w/ enough shares
    stake = minStake;
    grantShares(member1, stake);
    vm.prank(member1);
    shaman.stakeAndClaim(stake, member1, claimsHatter);

    // member is placed in bad standing
    vm.prank(judge);
    shaman.setStanding(member1, false);

    // bad standing is then set in Hats.sol so it will persist after the eligibility is removed
    HATS.checkHatWearerStatus(role1Hat, member1);

    // role1 is deregistered by changing the eligibility module, and member1 stays in bad standing
    vm.prank(roleAdmin);
    HATS.changeHatEligibility(role1Hat, eligibility);
    assertFalse(HATS.isInGoodStanding(member1, role1Hat), "not in bad standing");

    // member1 is slashed when attempting to unstake
    vm.prank(member1);
    vm.expectEmit();
    emit Slashed(member1, stake);
    shaman.unstakeFromDeregisteredRole();

    (retStakedAmount, retUnstakingAmount, retCanUnstakeAfter) = shaman.stakes(member1);
    assertEq(retStakedAmount, 0);
    assertEq(retUnstakingAmount, 0);
    assertEq(retCanUnstakeAfter, 0);
    assertEq(shaman.memberStakes(member1), 0);
    assertEq(shaman.SHARES_TOKEN().getVotes(member1), 0);
  }
}
