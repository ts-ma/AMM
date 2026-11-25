# A Constant-Product AMM with Measured Token Accounting

Coursework project for Blockchains and Distributed Ledgers: a constant-product automated market maker in Solidity 0.8.38, built and tested with Foundry. `AMMFactory` creates at most one `AMMPool` per token pair; each Pool issues LP shares, measures what it actually receives (a fee-on-transfer token is booked at the amount that actually arrived), swaps with a 0.3 % fee, and keeps recorded reserves apart from raw balances (`sync` / `skim`). Shared maths is in `AMMMath`.

## Where to start

- **Report:** [docs/REPORT.md](docs/REPORT.md). The submitted PDF is exported from commit `25a415e` (10 pages).
- **Final regression and gas comparison:** [docs/TEST_MATRIX.md](docs/TEST_MATRIX.md) §14.11. Final code `e951544`: 527 tests in 59 suites passed with `forge test` and with `FOUNDRY_FUZZ_RUNS=10000 forge test`.
- **Design records:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/DECISIONS.md](docs/DECISIONS.md), [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md), [docs/MILESTONES.md](docs/MILESTONES.md).
- **Talk plan:** [docs/TALK.md](docs/TALK.md).
- **Code:** [src/](src/) (contracts), [test/](test/) (unit, fuzz, invariant and gas tests).

## Reproduce

```shell
forge build
forge test
FOUNDRY_FUZZ_RUNS=10000 forge test
forge test --match-contract "GasG02|GasM11Combined" -vv   # gas values, TEST_MATRIX §14.11
```

Configuration: solc 0.8.38, optimizer 200 runs, `evm_version = osaka`, `via_ir = false`, `isolate = true`; forge 1.9.0; OpenZeppelin Contracts v5.7.0.

---

Toolchain notes from the Foundry template follow.

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

No deployment script is provided: a deployment workflow is out of scope (docs/ARCHITECTURE.md §2, §10).

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
