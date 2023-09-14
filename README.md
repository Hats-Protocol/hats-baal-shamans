# Hats Baal Shamans

[Hats Protocol](https://hatsprotocol.xyz)-powered Shaman contracts for [Moloch V3 (Baal)](https://github.com/hausdao/baal).

This repo contains the contracts for the following Shamans:

- [Hats Onboarding Shaman](#hats-onboarding-shaman)
- [Hats Role Staking Shaman](#hats-role-staking-shaman)

## Hats Onboarding Shaman

A Baal manager shaman that allows onboarding, offboarding, and other DAO member management based on Hats Protocol hats. Members must wear the member hat to onboard or reboard, can be offboarded if they no longer wear the member hat, and kicked completely if they are in bad standing for the member hat. Onboarded members receive an initial share grant, and their shares are down-converted to loot when they are offboarded.

### Functions

```constructor(string memory _version)```

Constructor function that initializes the module with a version string.

```onboard()```

Onboards the caller to the DAO, if they are wearing the member hat. New members receive a starting number of shares.

```offboard(address[] calldata _members)```

Offboards a batch of members from the DAO, if they are not wearing the member hat. Offboarded members lose their voting power, but keep a record of their previous shares in the form of loot.

```offboard(address _member)```

Offboards a single member from the DAO, if they are not wearing the member hat. Offboarded members lose their voting power by having their shares down-converted to loot.

```reboard()```

Reboards the caller to the DAO, if they were previously offboarded but are once again wearing the member hat. Reboarded members regain their voting power by having their loot up-converted to shares.

```kick(address[] calldata _members)```

Kicks a batch of members out of the DAO completely, if they are in bad standing for the member hat. Kicked members lose their voting power and any record of their previous shares; all of their shares and loot are burned.

```kick(address _member)```

Kicks a single member out of the DAO completely, if they are in bad standing for the member hat. Kicked members lose their voting power and any record of their previous shares; all of their shares and loot are burned.

## Hats Role Staking Shaman

A Baal manager shaman that allows members of the DAO to stake their shares to earn a role. The DAO (or its delegate, the `ROLE_MANAGER`), can create new roles and/or register existing existing roles, each with a minimum staking requirement. Members can then stake their shares to receive the role. The DAO (or its delegate, the `JUDGE`), can put stakers in bad standing, resulting in their staked shares being slashed. If a staker's stake drops below the minimum staking requirement for a given role — whether via slashing or some other DAO action — they immediately lose that role.

Staking in this contract is "virtual" — stakers retain custody of their shares at all times, but this contract is authorized to burn the staked shares if slashing conditions are met. Stakers must always have sufficient shares to cover the total amount they have staked across all roles. If at any time they do not, they lose all roles and can only regain (a subset of) them by unstaking from enough roles to meet the coverage requirement for the remaining roles.

### Special Roles

The `ROLE_MANAGER` is a special role that can create new roles, set a staking requirement for (aka register) existing roles, or change/remove staking requirements for registered roles.

The `JUDGE` is a special role that can put stakers in bad standing.

Each role is defined by a hatId.

### Creating, Registering, and Deregistering DAO Roles

The `ROLE_MANAGER` can create, register, and deregister roles. Each role is a Hats Protocol hat, and referenced in this contract by its hatId.

Creating a new role or registering an existing role entails the following:

1. Setting a minimum staking threshold for that role, which sets an eligibility criterion for the hat.
2. Setting the Hats eligibility module for the hat. Typically, this will be the Hats Role Staking Shaman itself. But it could be another eligibility module that draws eligibility from the Hats Role Staking Shaman (see [Hats Eligibility Chaining](https://docs.hatsprotocol.xyz/for-developers/hats-modules/building-hats-modules/about-module-chains) for more info on how this can work).

Deregistering a role entails removing the minimum staking threshold for that role, which removes the eligibility criterion for the hat. Typically, this action would also be accompanied by changing the hat's eligibility module to a different module, but this is not stricly required.

The `ROLE_MANAGER` can also change the minimum staking threshold for a registered role.

### Staking and Claiming DAO Roles

DAO members that stake a sufficient number of shares on a given role are eligible to have that role (aka "wear that hat"). DAO members can stake shares on multiple roles, as long as they have sufficient shares to meet the minimum staking requirement for each role.

Note that DAO members can stake any amount they choose on a given role. They do not have to stake the minimum staking requirement. However, if they stake less than the minimum staking requirement, they will not be eligible to claim that role.

Why would a member choose to stake more than the minimum? One example is that if the hat's eligibility is some contract other than the Hats Role Staking Shaman itself — such as a module that also requires approval from the DAO — then staking a larger amount may increase the likelihood of the DAO approving them for that role.

Once a member has staked sufficient shares on a role, they can claim that role as long as they are eligible according to the hat's eligibility module. If the eligibility module is the Hats Role Staking Shaman itself, then as long as the member is in good standing, they can claim the hat, since the only eligibility requirement is sufficient stake. If the eligibility module is some other contract — such as the example from the previous paragraph — they must meet the other criteria as well.

For convenience, members can also stake on and claim a role in a single transaction.

Claiming a role mints the hat to the claimer.

### Unstaking from DAO Roles

DAO members can unstake from a role at any time. To ensure that stakers cannot game the system by unstaking their shares before they can be slashed, unstaking is subject to a cooldown period.

Like staking, members can unstake any amount they choose, as long as they are not unstaking more shares than they have staked on the given role or more shares than they have in their account. As always, dropping below the minimum staking requirement for a given role results in the member losing that role.

Here's how unstaking typically works:

1. A member starts with staked shares on a role, and are in good standing for that role.
2. They initiate the unstaking process by calling `beginUnstakeFromRole()`. This the amount of shares they want to unstake to an "unstaking" state, and begins the cooldown period. Within the cooldown period, the member's "unstaking" shares still count towards the minimum staking requirement, so they continue to have the role.
3. Once the cooldown period has elapsed, the member automatically loses the role. At this point, anybody (including the member) can call `completeUnstakeFromRole()` to finish the process. This transfers their shares back to their account, and clears the "unstaking" and cooldown data.

If at any point the member becomes in bad standing for the role, they will be slashed at the next stage of the unstaking process. No member in bad standing can receive back their staked shares.

#### Resetting the Unstaking Process

Sometimes, a staker may want to restart the unstaking process.

This can be for any reason, but the most common is that since their cooldown period began, their total shares has decreased such that they no longer have sufficient coverage of both staked shares and the amount they wish to unstake. In this case, `completeUnstakeFromRole()` would fail. Resetting would allow them to reduce the number of shares they are attempting to unstake to a number for which they have sufficient coverage.

Resetting the unstaking process has two effects: a) it changes the amount of the member's shares that are in "unstaking" state, and b) it restarts the cooldown period.

#### Unstaking from a Registered Role

When the role on which a member has been staked is deregistered, there is no need for a cooldown period. In this case, the member can call `unstakeFromDeregisteredRole()` to immediately withdraw their shares.

### Eligibility, Standing, and Slashing

This contract also serves as a Hats eligibility module. It is designed to be set as the eligibility module for each hat that is registered to it.

When set as the eligibility module for a registered hat, it will check both members' eligibility for the hat as well as their standing. 

`Eligibility` is determined by the following conditions. Both must be true for a member to be eligible for a given hat:

1. Has the member staked at least the minStake amount of shares for the role?
2. Does the member have sufficient shares to cover the total amount they have staked across all roles?

`Standing` is set by the wearer of the `JUDGE_HAT`. If a member is in bad standing, they can be slashed by any account. If they attempt any phase of unstaking, they will also be slashed.

## Development

This repo uses Foundry for development and testing. To get started:

1. Fork the project
2. Install [Foundry](https://book.getfoundry.sh/getting-started/installation)
3. To compile the contracts, run `forge build`
4. To test, run `forge test`
