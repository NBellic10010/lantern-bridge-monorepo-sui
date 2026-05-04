# Sui Builder Monthly Report - April 2026

## Basic Information

| Item | Content |
|------|---------|
| **GitHub Repository** | https://github.com/NBellic10010/lantern-bridge-monorepo-sui |
| **GitHub Username** | NBellic10010 |

---

## Execution Path

- ✅ **Move smart contracts** - Sui Move contract development
- ✅ **Application / backend integration** - Backend SDK integration

---

## Work Completed This Month

### 1. P0+P1 Yield Layer Security Fixes (May 2-4)

**Description**: Implemented critical security and yield-generation fixes across admin governance, vault fee routing, and Navi Protocol integration.

#### Admin Module Hardening (`admin.move`)

- Added `admin: address` field to `Config` struct — enables ownership verification
- Implemented `verify_admin(cap, config, ctx)` with real validation (cap existence + sender/admin match)
- All admin functions now require `ctx: &mut TxContext` parameter
- Added `get_admin(config): address` getter

#### Vault Fee Routing (`vault.move`)

- `deposit()` and `withdraw()` signatures now include `config: &Config` parameter
- Implemented real fee routing: `fee = amount * fee_rate / 10000`, fee coin transferred to treasury address
- Updated `n_token` comment to clarify vault is pure accounting layer; Navi receipt held by Relayer backend
- Enabled `WithdrawEvent` emit (deposit emit remains TODO for future activation)

#### Cross-Chain Module Fix (`cross_chain.move`)

- Fixed `add_relayer()` and `remove_relayer()` signatures — added `ctx: &mut TxContext` parameter
- Relayer permission check now uses `sender(ctx)` membership in `config.relayers` list

#### Relayer Navi Integration (`relayer.service.ts`)

- Added `depositToNavi()` using `@naviprotocol/lending` `depositCoinPTB`
- `relayEvmNttToSui()` now appends Navi deposit after cross-chain completion (for `yieldMode === 'yield'`)
- Deposited USDC coin identified from `objectChanges` after `ntt_manager::redeem()`
- Navi SDK package: `@naviprotocol/lending@1.0.6`
- USDC coinType confirmed: `0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC`

#### Deployment Infrastructure

- Created `deploy-mainnet.sh` — automated build and publish script
- Created `DEPLOY.md` — detailed deployment guide with Config migration notes
- **⚠️ Breaking change**: `Config` struct change (new `admin` field) requires fresh initialization on deploy; old Config object cannot be upgraded in-place

---

## Sui Stack Components Used

- **Sui Move** - Smart contract development (admin governance, vault, cross-chain)
- **Programmable Transaction Blocks (PTB)** - Atomic cross-chain + Navi deposit operations
- **Navi Protocol SDK** (`@naviprotocol/lending`) - Yield generation via lending pool deposits
- **Wormhole NTT** - Cross-chain message passing (existing)
- **Pyth Oracle** - TVL calculation (existing)

---

## Integration Description

**Yield Flow (EVM → Sui, YieldMode.YIELD)**:

```
User deposits USDC on EVM
  → Wormhole NTT relay
    → relayEvmNttToSui() executes ntt_manager::redeem() [mint USDC to user]
      → depositToNavi() executes depositCoinPTB() [USDC → Navi vault → nUSDC]
        → nUSDC held by Relayer address
```

**Vault Architecture**: Pure ERC-4626 accounting layer (shares ↔ assets). Actual USDC lives in Relayer's Navi vault. On withdrawal, Relayer backend redeems nUSDC from Navi and delivers USDC to user.

> ⚠️ **Known Limitation**: Current Relayer-as-custodian model is not ideal for production scale. Upgrade path: move Navi receipt (nUSDC) directly into `vault.n_token` via on-chain PTB so vault share is fully backed by on-chain assets. See DEPLOY.md for details.

---

## Verifiable Technical Evidence

### GitHub Commits

1. **feat: P0+P1 yield layer fixes** (2026-05-04)
   - Commit: `4d98564`
   - URL: https://github.com/NBellic10010/lantern-bridge-monorepo-sui/commit/4d98564
   - Description: Admin governance hardening, fee routing, Navi SDK integration, deployment scripts

2. **ntt transfer 0328** (2026-03-28)
   - Commit: `1d90dd57c54aad2716f96be28ccaea8da88736d0`
   - URL: https://github.com/NBellic10010/lantern-bridge-monorepo-sui/commit/1d90dd57c54aad2716f96be28ccaea8da88736d0
   - Description: NTT transfer core functionality implementation

3. **0228: Add risk controls & cross chain message support** (2026-02-28)
   - Commit: `0458955558e58d4857843172474106f86ede8cc0`
   - URL: https://github.com/NBellic10010/lantern-bridge-monorepo-sui/commit/0458955558e58d4857843172474106f86ede8cc0
   - Description: Risk controls, cross-chain message support, vault tests

---

## Code File Changes Summary

| File | Change Type | Function |
|------|-------------|----------|
| `lantern-contracts/sources/admin.move` | Updated | Admin governance + verify_admin |
| `lantern-contracts/sources/vault.move` | Updated | Fee routing + Config integration |
| `lantern-contracts/sources/cross_chain.move` | Updated | add_relayer/remove_relayer fix |
| `lantern-backend/src/services/relayer.service.ts` | Updated | Navi depositCoinPTB integration |
| `lantern-backend/package.json` | Updated | Added @naviprotocol/lending |
| `lantern-contracts/deploy-mainnet.sh` | Created | Mainnet deployment script |
| `lantern-contracts/DEPLOY.md` | Created | Deployment guide |

---

## Upcoming Work

- [ ] Deploy updated contracts to Sui Mainnet (see DEPLOY.md)
- [ ] Update Relayer env vars with new Config ID post-deployment
- [ ] Test end-to-end: EVM deposit → Sui receive → Navi deposit → yield accrual
- [ ] Upgrade path: vault.n_token direct Navi integration (remove Relayer as custodian)
- [ ] Enable `DepositEvent` emit in vault.move
- [ ] Delta-neutral hedging for Junior tranche risk (pre-Tranche launch)

---
