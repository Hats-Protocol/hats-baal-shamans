# Hats Baal Shamans

[Hats Protocol](https://hatsprotocol.xyz)-powered Shaman contracts for [Moloch V3 (Baal)](https://github.com/hausdao/baal).

This repo contains the contracts for the following Shamans:

- [Hats Onboarding Shaman](#hats-onboarding-shaman)
- [Hats Staking Shaman](#hats-staking-shaman)

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

## Hats Staking Shaman

A Baal manager shaman that allows members of the DAO to stake their shares to earn a given hat. The shaman is set as the eligibility module for the given hat, and the hat's admin(s) can modify its settings, including the minimum staking requirement. Members can then stake their shares to receive the hat. The DAO (or its delegate, the `judge`), can put stakers in bad standing, resulting in their staked shares being slashed. If a staker's stake drops below the minimum staking requirement for a given hat — whether via slashing or some other DAO action — they immediately lose that hat.

### Special Roles

The `judge` is a special role that can put stakers in bad standing. It is defined by a hatId.

### Staking and Claiming DAO Roles

DAO members that stake a sufficient number of shares on a given role are eligible to have that role (aka "wear that hat").

Note that DAO members can stake any amount they choose on a given role. They do not have to stake the minimum staking requirement. However, if they stake less than the minimum staking requirement, they will not be eligible to claim that role.

Why would a member choose to stake more than the minimum? One example is when there are other eligibility requirements set on the hat via chained eligibility — such as a module that also requires approval from the DAO — then staking a larger amount may increase the likelihood of the DAO approving them for that role.

Once a member has staked sufficient shares on a role, they can claim that hat as long as they are eligible according to the hat's eligibility module.

For convenience, members can also stake on and claim a role in a single transaction. This requires that a [MultiClaimsHatter](https://github.com/hats-protocol/multi-claims-hatter) be correctly configured in the hat's tree.

Claiming a role mints the hat to the claimer.

### Unstaking from DAO Roles

DAO members can unstake from a role at any time. However, to prevent gaming the system, unstaking is subject to a cooldown period.

Like staking, members can unstake any amount they choose, as long as they have sufficient shares staked on that role. As always, dropping below the minimum staking requirement for a given role results in the member losing that role.

Here's how unstaking typically works:

1. A member starts with staked shares on a role, and are in good standing for that role.
2. They initiate the unstaking process by calling `beginUnstake()`. This converts the amount of shares they want to unstake to an "unstaking" state, and begins the cooldown period. Within the cooldown period, the member's "unstaking" shares still count towards the minimum staking requirement, so they continue to have the role.
3. Once the cooldown period has elapsed, the member automatically loses the role. At this point, anybody (including the member) can call `completeUnstake()` to finish the process. This transfers their shares back to their account, and clears the "unstaking" and cooldown data.

If at any point the member becomes in bad standing for the role, they will be slashed at the next stage of the unstaking process. No member in bad standing can receive back their staked shares.

#### Resetting the Unstaking Process

Sometimes, a staker may want to restart the unstaking process.

This can be for any reason, but the most common is that since their cooldown period began, their staked shares have been reduced (such as by another shaman burning them). In this case, `completeUnstake()` would fail, since they would no longer have sufficient shares to withdraw. Resetting would allow them to reduce the number of shares they are attempting to unstake to a number they can actually withdraw.

Resetting the unstaking process has two effects: a) it changes the amount of the member's shares that are in "unstaking" state, and b) it restarts the cooldown period.

#### Unstaking from a Registered Role

If the Hats Staking Shaman is removed as an eligibility module from the hat, there is no need for a cooldown period. In this case, the member can call `unstakeFromDeregisteredRole()` to immediately withdraw their shares.

### The Staking Proxy

A member's Baal shares have voting rights that can be delegated to other accounts of the member's choosing. In order to preserve this property while their shares are staked, staked shares are held in a staking proxy contract.

This contract is a simple proxy that has just a single function: `delegate()`. Each member has their own staking proxy, which is deployed when they stake shares for the first time.

Whenever the member stakes additional shares — such as when calling `stake()` or `stakeAndClaim()`, those shares are transferred to their staking proxy and the associated voting power is delegated to the account of their choosing (eg themselves or a desired delegate). When the member unstakes shares, the shares are transferred back to their account and the associated voting power defaults back to the member.

The member can redelegate their staked shares at any time by calling `delegate()` on their staking proxy.

The address of a given member's staking proxy can be found by calling `getStakedSharesAndProxy()`. This function returns both the member's staking proxy address as well as the total shares held in that proxy.

## Development

This repo uses Foundry for development and testing. To get started:

1. Fork the project
2. Install [Foundry](https://book.getfoundry.sh/getting-started/installation)
3. To compile the contracts, run `forge build`
4. To test, run `forge test`
