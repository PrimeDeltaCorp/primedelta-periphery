# Primelta-Dev Periphery + DEX Deployment — 2026-04-17

Periphery-side summary of the 2026-04-17 full redeployment. Authoritative cross-repo record is in [`primedelta-monorepo/dclex-blockchain/deployments/PRIMELTA_DEV_DEPLOYMENT_2026-04-17.md`](../../dclex-blockchain/deployments/PRIMELTA_DEV_DEPLOYMENT_2026-04-17.md).

## Chain
- Chain ID **2028** (Besu, primelta-dev)
- RPC: `https://besu-dev.primedelta.io`
- `INITIAL_BLOCK_NUMBER=1046`

## V3 Infrastructure (DeployV3Production.s.sol)
| Contract | Address |
|----------|---------|
| WDEL | `0x0b48af34f4c854f5ae1a3d587da471fea45bad52` |
| DclexV3Factory | `0x0f5d1ef48f12b6f691401bfe88c2037c690a6afe` |
| V3 SwapRouter | `0x90118d110b07abb82ba8980d1c5cc96eea810d2c` |
| V3 Quoter | `0xca03dc4665a8c3603cb4fd5ce71af9649dc00d44` |
| DclexPositionManager | `0x2de080e97b0cae9825375d31f5d0ed5751fdf16d` |

All five have DID minted (DID-gated transfers require this).

## DclexRouter + Custom Pools (DeployDclexRouterWithPools.s.sol)
| Contract | Address |
|----------|---------|
| DclexRouter | `0xe6b98f104c1bef218f3893adab4160dc73eb8367` |
| FIOracle | `0x381445710b5e73d34af196c53a3d5cda58edbf7a` (deployed by HelperConfig.getPrimeltaDevConfig) |

44 `DclexPool` contracts deployed in one batch via `BatchPoolDeployer` (one per non-AMM stock, paired with dUSD). `maxPriceStaleness = 86400s`, fee curve 1% base.

Router config:
- `router.usdc()` → `0xb95aa96625C6854E1B44af092D3aA2fF4Aa72870` (USDCMock used as dUSD on dev)
- `router.swapRouter()` → V3 SwapRouter
- `router.quoter()` → V3 Quoter

## DEX — AMM Test Tokens (DeployAMMStocks.s.sol)

Creates AMMT1/AMMT2 as Factory stocks, adds V3 pools paired with dUSD, registers with `router.setAMMPool(stock, pool, 3000)`, seeds initial liquidity for AMMT1.

| Symbol | Stock Address | V3 Pool | Initial Price | Liquidity |
|--------|--------------|---------|---------------|-----------|
| AMMT1 | `0x0b00D8C36f97fA5e9481f9147A66Ad776aBe8E0b` | `0x1C267b3Bda054868AD76aFc85bec31f07508D807` | $10 | 100K AMMT1 + 1M dUSD (two-sided) |
| AMMT2 | `0x00FA0AF383975D06C8F1B24eDbD8C4605A4d5694` | `0x3a7F7F888171AfDf36A2af29E1D63C0F9A1fA4b1` | $20 | Empty (by design — tests "add liquidity" UI) |
| WDEL | `0x0b48af34f4c854f5ae1a3d587da471fea45bad52` | `0xbaE0b2763d0F336205Cb47B10772f82C8cAc9eA8` | $0.01 | Empty (see note) |

All three pools use FEE_TIER = **3000** (0.3%). `router.getPoolType(token)` returns `2` (AMM) for each.

### WDEL liquidity note
`WDEL.mint(address,uint256)` is guarded to `chainid == 31337`. The original `DeployAMMStocks.s.sol` reverted mid-simulation on primelta-dev because of this, so the entire script never broadcast. Fix is in [`dclex-periphery#7`](https://github.com/dclex-platform/dclex-periphery/pull/7) — `_addWdelLiquidity` now short-circuits on non-local chains, pool is still created/initialized/DID-minted/registered but left empty. Must land before next fresh deploy or the guard-patch must be re-applied manually.

## Admin role quirk

`DeployDclexRouterWithPools.s.sol:_executeBatchDeploy` calls:
```solidity
did.grantRole(did.DEFAULT_ADMIN_ROLE(), address(batch));
```
`MASTER_ADMIN_ROLE` is the role admin of `DEFAULT_ADMIN_ROLE` — so the broadcaster (Admin key, `0x70997970...`) needs `MASTER_ADMIN` on DID. `DeployProduction` only grants DEFAULT_ADMIN, so this reverted first pass. Fix before running Router script:

```bash
ROLE_MASTER=0xf83591f6d256ac9a12084d6de9c89a3e1fd09d594aa1184c76eef05bae103fc3
cast send $DID "grantRole(bytes32,address)" $ROLE_MASTER $ADMIN \
  --rpc-url $RPC --private-key $MASTER_ADMIN_KEY --legacy --gas-price 1000000000000
```

## Gas & Tx shapes (for future plan sizing)
- `DeployV3Production`: ~17.5M gas estimate, <10 tx
- `DeployDclexRouterWithPools`: ~192M gas estimate, **140 tx** (one per pool init + router wiring). Admin needs ~150 DEL. **Do NOT use `--slow`** — hangs on Besu FIFO mempool. Without `--slow`, completes in ~3 min.
- `DeployAMMStocks`: ~27.6M gas estimate, ~20 tx
