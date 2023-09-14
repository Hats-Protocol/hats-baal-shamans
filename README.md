# Hats Baal Shamans

[Hats Protocol](https://hatsprotocol.xyz)-powered Shaman contracts for [Moloch V3 (Baal)](https://github.com/hausdao/baal).

This repo contains the contracts for the following Shamans:

- [Hats Onboarding Shaman](#hats-onboarding-shaman)

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

## Development

This repo uses Foundry for development and testing. To get started:

1. Fork the project
2. Install [Foundry](https://book.getfoundry.sh/getting-started/installation)
3. To compile the contracts, run `forge build`
4. To test, run `forge test`
