// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Test, console2 } from "forge-std/Test.sol";
import { HatsOnboardingShaman } from "../../src/HatsOnboardingShaman.sol";
import { HatsStakingShaman } from "../../src/HatsStakingShaman.sol";
import {
  HatsModuleFactory, deployModuleFactory, deployModuleInstance
} from "lib/hats-module/src/utils/DeployFunctions.sol";

contract IntegrationTest is Test {
// TODO
// set up hats
// deploy hats module factory
// deploy HatsStakingShaman instance
// deploy HatsOnboardingShaman instance
}

contract OnboardWithRoleStakingShaman is IntegrationTest { }

contract OffboardWithRoleStakingShaman is IntegrationTest { }

contract KickWithRoleStakingShaman is IntegrationTest { }
