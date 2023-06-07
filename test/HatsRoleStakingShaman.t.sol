// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import { Test, console2 } from "forge-std/Test.sol";
import { HatsRoleStakingShaman } from "../src/HatsRoleStakingShaman.sol";
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

  // add errors

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

  uint256 public tophat;
  uint256 public shamanHat;
  uint256 public roleManagerHat;
  uint256 public judgeHat;
  uint256 public role1Hat;
  uint256 public role2Hat;
  address public eligibility = makeAddr("eligibility");
  address public toggle = makeAddr("toggle");
  address public dao = makeAddr("dao");
  address public judge = makeAddr("judge");
  address public roleManager = makeAddr("roleManager");

  address public wearer1 = makeAddr("wearer1");
  address public wearer2 = makeAddr("wearer2");
  address public wearer3 = makeAddr("wearer3");
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

  function setUp() public virtual override {
    super.setUp();
    cooldownBuffer = 1 days;

    // set up hats
    tophat = HATS.mintTopHat(dao, "tophat", "dao.eth/tophat");
    vm.startPrank(dao);
    shamanHat = HATS.createHat(tophat, "shamanHat", 1, eligibility, toggle, true, "dao.eth/shamanHat");
    roleManagerHat = HATS.createHat(tophat, "roleManagerHat", 1, eligibility, toggle, true, "dao.eth/roleManagerHat");
    judgeHat = HATS.createHat(tophat, "judgeHat", 1, eligibility, toggle, true, "dao.eth/judgeHat");
    HATS.mintHat(roleManagerHat, roleManager);
    HATS.mintHat(judgeHat, judge);
    vm.stopPrank();

    // deploy the staking proxy implementation
    stakingProxyImplementation = new StakingProxy();

    // deploy the hats module factory
    factory = deployModuleFactory(HATS, SALT, FACTORY_VERSION);

    // predict the baal's address
    predictedBaalAddress = predictBaalAddress(SALT);

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

contract CreatingRoles is WithInstanceTest { }

contract RegisteringRoles is WithInstanceTest { }

contract UnregisteringRoles is WithInstanceTest { }

contract SettingMinStake is WithInstanceTest { }

contract SettingStanding is WithInstanceTest { }

contract GettingWearerStatus is WithInstanceTest { }

contract Staking is WithInstanceTest { }

contract Claiming is WithInstanceTest { }

contract StakingAndClaiming is WithInstanceTest { }

contract BeginUnstaking is WithInstanceTest { }

contract CompleteUnstaking is WithInstanceTest { }

contract Unstaking is WithInstanceTest { }

contract Slashing is WithInstanceTest { }

contract ViewFunctions is WithInstanceTest {
// cooldownPeriod
// getStakedSharesAndProxy
}
