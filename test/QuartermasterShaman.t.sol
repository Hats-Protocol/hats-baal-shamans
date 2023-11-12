// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test } from "forge-std/Test.sol";
import { QuartermasterShaman } from "../src/QuartermasterShaman.sol";
import { DeployImplementation } from "../script/QuartermasterShaman.s.sol";
import {
  IHats,
  HatsModuleFactory,
  deployModuleFactory,
  deployModuleInstance
} from "lib/hats-module/src/utils/DeployFunctions.sol";
import { IBaal } from "baal/interfaces/IBaal.sol";
import { IBaalToken } from "baal/interfaces/IBaalToken.sol";
import { IBaalSummoner } from "baal/interfaces/IBaalSummoner.sol";

contract QuartermasterShamanTest is DeployImplementation, Test {
  // variables inherited from DeployImplementation script
  // QuartermasterShaman public implementation;
  // bytes32 public SALT;

  uint256 public fork;
  uint256 public BLOCK_NUMBER = 17_671_864; // the block number where v1.hatsprotocol.eth was deployed;

  IHats public constant HATS = IHats(0x3bc1A0Ad72417f2d411118085256fC53CBdDd137); // v1.hatsprotocol.eth
  string public FACTORY_VERSION = "factory test version";
  string public SHAMAN_VERSION = "shaman test version";

  error NotCaptain();

  event OnboardedBatch(address[] members, uint256[] sharesPending, uint256 delay);
  event OffboardedBatch(address[] members, uint256[] sharesPending, uint256 delay);
  event Quartered(address[] members, uint256[] shares);
  event Unquartered(address[] members, uint256[] shares);

  function setUp() public virtual {
    // create and activate a fork, at BLOCK_NUMBER
    fork = vm.createSelectFork(vm.rpcUrl("mainnet"), BLOCK_NUMBER);

    // deploy via the script
    DeployImplementation.prepare(SHAMAN_VERSION, false); // set last arg to true to log deployment addresses
    DeployImplementation.run();
  }
}

contract WithInstanceTest is QuartermasterShamanTest {
  HatsModuleFactory public factory;
  QuartermasterShaman public shaman;
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

  uint256 public tophat;
  uint256 public captainHat;
  address public eligibility = makeAddr("eligibility");
  address public toggle = makeAddr("toggle");
  address public dao = makeAddr("dao");
  address public captain = makeAddr("captain");
  address public nonWearer = makeAddr("nonWearer");

  address public predictedBaalAddress;
  address public predictedShamanAddress;

  uint256 public constant MIN_STARTING_SHARES = 1e18;

  function deployInstance(address _baal, uint256 _captainHat, uint256 _startingShares)
    public
    returns (QuartermasterShaman)
  {
    // encode the other immutable args as packed bytes
    otherImmutableArgs = abi.encodePacked(_baal, _captainHat, _startingShares);
    // encoded the initData as unpacked bytes -- for QuartermasterShaman, we just need any non-empty bytes
    initData = abi.encode(0);
    // deploy the instance
    return QuartermasterShaman(deployModuleInstance(factory, address(implementation), 0, otherImmutableArgs, initData));
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
    bytes memory governanceConfig = abi.encode(uint32(3600), uint32(0), uint256(0), uint256(0), uint256(0), uint256(0));
    shamans[0] = _shaman;
    permissions[0] = 2; // manager only
    bytes[] memory initializationActions = new bytes[](2);
    initializationActions[0] = abi.encodeCall(IBaal.setShamans, (shamans, permissions));
    initializationActions[1] = abi.encodeCall(IBaal.setGovernanceConfig, (governanceConfig));
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

  function makeArray(address _addr) public pure returns (address[] memory) {
    address[] memory addrArray = new address[](1);
    addrArray[0] = _addr;
    return addrArray;
  }

  function makeArray(uint256 _num) public pure returns (uint256[] memory) {
    uint256[] memory numArray = new uint256[](1);
    numArray[0] = _num;
    return numArray;
  }

  function setUp() public virtual override {
    super.setUp();
    // set startingShares at 1
    startingShares = 1 ether; // 1 shares

    // deploy the hats module factory
    factory = deployModuleFactory(HATS, SALT, FACTORY_VERSION);

    // set up hats
    tophat = HATS.mintTopHat(dao, "tophat", "dao.eth/tophat");
    vm.startPrank(dao);
    captainHat = HATS.createHat(tophat, "captainHat", 1, eligibility, toggle, true, "dao.eth/captainHat");
    HATS.mintHat(captainHat, captain);
    vm.stopPrank();

    // predict the baal's address
    predictedBaalAddress = predictBaalAddress(SALT);

    // predict the shaman's address via the hats module factory
    predictedShamanAddress = factory.getHatsModuleAddress(
      address(implementation), 0, abi.encodePacked(predictedBaalAddress, captainHat, startingShares)
    );

    // deploy a test baal with the predicted shaman address
    baal = deployBaalWithShaman("TEST_BAAL", "TEST_BAAL", SALT, predictedShamanAddress);

    // find and set baal token addresses
    sharesToken = IBaalToken(baal.sharesToken());

    // deploy the shaman instance
    shaman = deployInstance(predictedBaalAddress, captainHat, startingShares);

    // ensure that the actual and predicted addresses are the same
    require(address(baal) == predictedBaalAddress, "actual and predicted baal addresses do not match");
    require(address(shaman) == predictedShamanAddress, "actual and predicted shaman addresses do not match");
  }
}

contract Deployment is WithInstanceTest {
  function test_setAsManagerShaman() public {
    assertEq(baal.shamans(address(shaman)), 2);
  }

  function test_version() public {
    assertEq(shaman.version(), SHAMAN_VERSION);
  }

  function test_baal() public {
    assertEq(address(shaman.BAAL()), address(baal));
    assertEq(address(shaman.BAAL()), predictBaalAddress(SALT));
  }

  function test_sharesToken() public {
    assertEq(address(shaman.SHARES_TOKEN()), address(sharesToken));
  }

  function test_startingShares() public {
    assertEq(shaman.STARTING_SHARES(), startingShares);
  }
}

contract Onboarding is WithInstanceTest {
  function test_captain_canOnboard() public {
    address[] memory toOnboard = makeArray(nonWearer);
    uint256[] memory shareArr = makeArray(startingShares);
    vm.prank(captain);
    vm.expectEmit(true, true, false, false);
    emit OnboardedBatch(toOnboard, shareArr, 0);
    shaman.onboard(toOnboard);

    assertGt(shaman.onboardingDelay(nonWearer), 0);
  }

  function test_nonCaptain_reverts() public {
    vm.prank(nonWearer);
    vm.expectRevert(NotCaptain.selector);
    address[] memory toOnboard = makeArray(nonWearer);
    shaman.onboard(toOnboard);

    assertEq(shaman.onboardingDelay(nonWearer), 0);
  }

  function test_hasShares_noop() public {
    uint256 amount = 1 ether;
    address[] memory toOnboard = makeArray(nonWearer);
    vm.prank(address(baal));
    sharesToken.mint(nonWearer, amount);

    vm.prank(captain);
    shaman.onboard(toOnboard);

    assertEq(shaman.onboardingDelay(nonWearer), 0);
  }

  function test_inQueue_noop() public {
    address[] memory toOnboard = makeArray(nonWearer);

    vm.prank(captain);
    shaman.onboard(toOnboard);

    uint256 delay = shaman.onboardingDelay(nonWearer);

    vm.warp(block.timestamp + 3600);

    vm.prank(captain);
    shaman.onboard(toOnboard);

    assertEq(shaman.onboardingDelay(nonWearer), delay);
  }
}

contract Quartering is WithInstanceTest {
  function test_captain_canQuarter() public {
    address[] memory toOnboard = makeArray(nonWearer);
    uint256[] memory amounts = makeArray(startingShares);

    vm.prank(captain);
    shaman.onboard(toOnboard);
    vm.warp(block.timestamp + 7200);

    vm.prank(captain);
    vm.expectEmit(true, false, false, true);
    emit Quartered(toOnboard, amounts);
    shaman.quarter(toOnboard);

    assertEq(sharesToken.balanceOf(nonWearer), startingShares);
    assertEq(shaman.onboardingDelay(nonWearer), 0);
  }

  function test_captain_tooSoon() public {
    address[] memory toOnboard = makeArray(nonWearer);

    vm.prank(captain);
    shaman.onboard(toOnboard);
    vm.warp(block.timestamp + 3600); // not long enough

    vm.prank(captain);
    shaman.quarter(toOnboard);

    assertEq(sharesToken.balanceOf(nonWearer), 0);
  }

  function test_anyone_canQuarter() public {
    address[] memory toOnboard = makeArray(nonWearer);

    vm.prank(captain);
    shaman.onboard(toOnboard);
    vm.warp(block.timestamp + 7200);

    vm.prank(nonWearer);
    shaman.quarter(toOnboard);

    assertEq(sharesToken.balanceOf(nonWearer), startingShares);
    assertEq(shaman.onboardingDelay(nonWearer), 0);
  }

  function test_notOnboarded() public {
    address[] memory toOnboard = makeArray(nonWearer);

    vm.prank(captain);
    shaman.quarter(toOnboard);

    assertEq(sharesToken.balanceOf(nonWearer), 0);
  }
}

contract WithQuarteredTest is WithInstanceTest {
  function setUp() public virtual override {
    super.setUp();
    address[] memory toOnboard = makeArray(nonWearer);

    // onboard and quarter
    vm.prank(captain);
    shaman.onboard(toOnboard);
    vm.warp(block.timestamp + 7200);
    vm.prank(nonWearer);
    shaman.quarter(toOnboard);
  }
}

contract Offboarding is WithQuarteredTest {
  function test_captain_canOffboard() public {
    address[] memory toOffboard = makeArray(nonWearer);
    uint256[] memory amounts = makeArray(startingShares);
    vm.prank(captain);
    vm.expectEmit(false, false, false, false);
    emit OffboardedBatch(toOffboard, amounts, 0);
    shaman.offboard(toOffboard);

    assertGt(shaman.offboardingDelay(nonWearer), 0);
  }

  function test_notCaptain_noop() public {
    address[] memory toOffboard = makeArray(nonWearer);
    vm.prank(nonWearer);
    vm.expectRevert(NotCaptain.selector);
    shaman.offboard(toOffboard);

    assertEq(shaman.offboardingDelay(nonWearer), 0);
  }

  function test_inQueue_noop() public {
    address[] memory toOffboard = makeArray(nonWearer);

    vm.prank(captain);
    shaman.offboard(toOffboard);

    uint256 delay = shaman.offboardingDelay(nonWearer);

    vm.warp(block.timestamp + 3600);

    vm.prank(captain);
    shaman.offboard(toOffboard);

    assertEq(shaman.offboardingDelay(nonWearer), delay);
  }
}

contract Unquartering is WithQuarteredTest {
  function setUp() public override {
    super.setUp();

    address[] memory toOffboard = makeArray(nonWearer);
    vm.prank(captain);
    shaman.offboard(toOffboard);
  }

  function test_canUnquarter() public {
    address[] memory toUnquarter = makeArray(nonWearer);
    vm.warp(block.timestamp + 7200);
    vm.prank(nonWearer);

    assertEq(sharesToken.balanceOf(nonWearer), startingShares);

    shaman.unquarter(toUnquarter);

    assertEq(sharesToken.balanceOf(nonWearer), 0);
  }

  function test_tooSoon_noop() public {
    address[] memory toUnquarter = makeArray(nonWearer);
    vm.warp(block.timestamp + 3600);

    vm.prank(nonWearer);
    shaman.unquarter(toUnquarter);

    assertEq(sharesToken.balanceOf(nonWearer), startingShares);
  }
}
