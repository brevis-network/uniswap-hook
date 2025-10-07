# Unified AEGIS–Brevis Uniswap v4 Hook Design

## Overview and objectives

We propose a unified Uniswap v4 hook contract that combines Brevis VIP discounting with AEGIS dynamic fees and reinvestment. The new `VipHook` will inherit from AEGIS’s `Spot` hook to reuse its dynamic fee logic and Full-Range Liquidity reinvestment, while preserving Brevis-specific features via multiple inheritance.

The unified hook must support:

- **Brevis ZK VIP Discounts**: Per-user fee reductions verified via ZK proof off-chain and applied on-chain by overriding the swap fee for VIP traders. This uses a discount mapping (`VipDiscountMap`) and identifies the end-user using `tx.origin` to fetch their discounted fee tier.
- **AEGIS Dynamic Fees**: On-chain dynamic fee calculation (base + surge) from `DynamicFeeManager` and `TruncGeoOracle`, with optional manual override via `PoolPolicyManager`. The hook adjusts the Uniswap pool’s fee each swap according to current volatility and policy parameters.
- **AEGIS Reinvestment Logic**: Automatic reinvestment of accumulated protocol fees into the pool via `FullRangeLiquidityManager` (FRLM). Collected fees are minted to FRLM and reinvested (unless paused) to grow protocol-owned liquidity.

Key requirements:

- **CREATE2 proxy compatibility**: Deployable behind Brevis’s CREATE2-based proxy scheme (with encoded permission bits).
- **Storage layout compatibility**: Maintain compatibility with the existing Brevis hook for safe upgrades.
- **Minimal churn**: Minimize changes to existing code by extending `Spot.sol` rather than modifying it. All existing Brevis admin functionality (discount mapping updates, proof verification callbacks, `Ownable` controls) should compose cleanly with the inherited AEGIS logic.

---

## Inheritance structure and storage layout

### Inheritance layout

We adopt multiple inheritance so that `VipHook` inherits from `Spot` (which itself extends Uniswap’s `BaseHook`) as well as from the Brevis modules `VipDiscountMap`, `BrevisApp`, and `Ownable`.

Hierarchy:

- `BaseHook` (Uniswap v4 periphery abstract hook base)
- `Spot` (AEGIS hook implementation, extends `BaseHook`)
- `VipHook` (Unified Hook) – extends `Spot`, `VipDiscountMap`, `BrevisApp`, `Ownable`

VipHook implements the Brevis-specific logic by inheriting `VipDiscountMap` (handles the `feeDiscount` mapping and discount math), `BrevisApp` (proof verification callbacks), and `Ownable` (admin control). The inheritance is carefully ordered to preserve the original storage layout of the Brevis hook:

```solidity
contract VipHook is VipDiscountMap, BrevisApp, Ownable, Spot { /* ... */ }
```

By listing `VipDiscountMap` and `BrevisApp` before `Spot`, storage slots align with the old `VipHook`. In this order:

- Brevis’s `feeDiscount` mapping remains in the same slot as before (slot 0)
- `BrevisApp`’s `brevisRequest` address and challenge window remain in the next slot
- AEGIS’s `Spot` state follows
- Ownable next
- `Spot` introduces a `reinvestmentPaused` boolean; in this layout it occupies previously unused padding space in an existing slot, so no existing variables are shifted

Critical variables like the discount mapping, the Brevis request contract address, the stored base fee (`origFee`), and the verifying keys map (`vkMap`) remain at their original storage slots and offsets, preserving proxy storage compatibility and upgrade safety.

### Constructor and init

`VipHook` defines a constructor that calls `Spot`’s constructor to set up AEGIS’s required immutables (the Uniswap `PoolManager` and the addresses of `liquidityManager` (FRLM), `policyManager`, `truncGeoOracle`, and `dynamicFeeManager`). These addresses are provided at deployment time.

All other initialization is done in an upgradeable-friendly `init()` function (called on the proxy) as in Brevis:

- Call `Ownable.initOwner(initialOwner)` to set the hook’s owner (Brevis admin)
- Register the initial ZK verification key
- Set the initial trusted `brevisRequest` contract address for proof callbacks if known
- Initialize the base fee (`origFee`) used for discount math as a reference tier; it can be updated via `setBaseFee`

### Spot constructor adaptation for proxy

`Spot`’s constructor validates that the FRLM’s authorized hook equals the hook address. This fails on logic-contract deployment (since `address(this)` is the logic address, not the proxy). Bypass this in the logic constructor and authorize the proxy post-deploy (e.g., via an FRLM admin function). Initialize the proxy immediately via `init()` to avoid uninitialized proxy risk.

---

## Hook permissions and callback mask

Uniswap v4 requires the hook contract’s address to encode its callback permissions in the lower 14 bits. The unified hook must support the union of Brevis and AEGIS `Spot` callbacks.

### Callback comparison

| Hook Callback                    | Brevis VipHook | AEGIS Spot | Unified VipHook |
|----------------------------------|----------------|------------|-----------------|
| beforeInitialize                 | False          | False      | False           |
| afterInitialize                  | True           | True       | True            |
| beforeAddLiquidity               | False          | False      | False           |
| afterAddLiquidity                | False          | False      | False           |
| beforeRemoveLiquidity            | False          | False      | False           |
| afterRemoveLiquidity             | False          | False      | False           |
| beforeSwap                       | True           | True       | True            |
| afterSwap                        | False          | True       | True            |
| beforeDonate                     | False          | False      | False           |
| afterDonate                      | False          | False      | False           |
| beforeSwapReturnDelta            | False          | True       | True            |
| afterSwapReturnDelta             | False          | True       | True            |
| afterAddLiquidityReturnDelta     | False          | False      | False           |
| afterRemoveLiquidityReturnDelta  | False          | False      | False           |

Unified permission mask: set `afterInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta` to 1. The combined 14-bit mask is `0xCC2` (hex) = `1100 1100 0010` (binary) = `3266` (decimal).

The deterministic deployment script must target this flags value when mining the CREATE2 salt so the proxy’s address encodes these bits. With the correct suffix, the `PoolManager` will invoke all required callbacks.

Rationale: This expanded set ensures post-swap processing and return-delta swap callbacks are available (needed for reinvestment and exact-in fee collection). Upgrading an old Brevis hook in place without changing address bits will not activate new callbacks; deploy a new hook address for full functionality.

---

## Unified swap fee logic (`_beforeSwap`)

We override `Spot._beforeSwap` in `VipHook` to insert VIP discount logic into AEGIS’s fee path. Steps:

1. **Identify trader**: Use `tx.origin` to determine the end-user (as in Brevis), since `msg.sender` may be a router.
2. **Fetch dynamic fee**: If `policyManager.getManualFee(poolId)` is set, use it; otherwise, query `dynamicFeeManager.getFeeState(poolId)` and sum base + surge.
3. **Apply VIP discount**: Read the user’s discount from `VipDiscountMap` and compute the effective fee as a percentage reduction of the dynamic fee.

   ```solidity
   uint24 baseFee = dynamicFee;
   uint16 discountBps = feeDiscount[trader].pctX100; // 2000 = 20.00%
   uint24 effectiveFee = discountBps > 0
       ? uint24(uint256(baseFee) * (10000 - discountBps) / 10000)
       : baseFee;
   ```

4. **Store fee and tick (transient)**: Persist `effectiveFee` and pre-swap tick to transient storage for use in `afterSwap`.
5. **Protocol fee (exact-in)**: If exact-in and `protocolFeePPM > 0`, compute the protocol portion using `effectiveFee`, mint that amount of the input token to FRLM via `poolManager.mint(liquidityManager, ...)`, notify FRLM, emit events, and return a positive delta to reduce input to the pool by the protocol fee amount.
6. **Return**: Return `(BaseHook.beforeSwap.selector, beforeSwapDelta, feeOverride)` with the dynamic fee override set to `effectiveFee`. If no protocol fee was taken (or exact-out), return zero deltas but still override the fee.

Implementation note: encapsulate discount math in `_applyBrevisDiscount(uint24 baseFee, address trader) returns (uint24)` to keep the override clean. All other logic mirrors `Spot._beforeSwap` and uses `effectiveFee` in place of the original `dynamicFee`.

Transient storage: We store the discounted fee, so `afterSwap` naturally computes exact-out protocol fees using the effective rate.

---

## Unified post-swap logic (`_afterSwap`) and reinvestment

We do not override `_afterSwap`; `VipHook` inherits `Spot`’s implementation. With the unified permissions mask, the pool calls `afterSwap`, and the inherited logic executes:

- **Oracle update**: Reads the stored pre-swap tick and fee, pushes a price observation to the oracle, and notifies the `DynamicFeeManager` of cap events.
- **Protocol fee (exact-out)**: If exact-out, compute protocol fee based on the stored effective fee and mint to FRLM, notify, and return the token delta.
- **Reinvestment**: Attempt to reinvest collected fees via FRLM unless paused. Errors are contained and logged.

Events from both systems are preserved (fee collection and reinvestment from `Spot`; proof-related events from Brevis modules).

---

## Brevis proof integration and admin functions

- **Discount updates**: `VipDiscountMap.updateBatch(bytes data)` is invoked from guarded Brevis callbacks to update multiple user discounts atomically.
- **Callbacks**: `brevisCallback(bytes proof, bytes data)` and `brevisBatchCallback(bytes proof, bytes data)` are callable only by the authorized `brevisRequest` contract. They verify proofs and apply updates.
- **Ownable & admin**: `Ownable` controls Brevis admin (verification keys, base fee, Brevis request address). Dynamic fee parameters and reinvestment control remain gated by `PoolPolicyManager`’s owner. This enforces least-privilege dual governance.
- **Brevis admin methods**: `setBaseFee(uint24)`, verifying key registration/removal, and `setBrevisRequest(address)` are preserved. `origFee` remains as a reference (not used in dynamic-fee swap paths but still useful for admin/compatibility).

Security: `onlyPoolManager` restricts Uniswap callbacks, `onlyBrevisRequest` restricts proof callbacks, `onlyOwner` restricts Brevis admin. Discount updates require valid proofs; there is no arbitrary write path.

---

## Code changes summary

### Spot.sol (AEGIS hook) – minimal

- Mark `getHookPermissions()`, `_beforeSwap(...)`, `_afterInitialize(...)` as `virtual` to allow overrides
- Optionally relax constructor checks that assume direct deployment; authorize the proxy post-deploy instead
- Reuse core logic unchanged

### VipHook.sol (Unified hook) – primary integration

- Extend `Spot` in addition to Brevis modules; preserve base-class order for storage:

  ```solidity
  contract VipHook is VipDiscountMap, BrevisApp, Spot, Ownable { /* ... */ }
  ```

- Remove direct `BaseHook` inheritance (covered by `Spot`)
- Constructor accepts: `IPoolManager`, `IFullRangeLiquidityManager`, `PoolPolicyManager`, `ITruncGeoOracleMulti`, `IDynamicFeeManager`; forward to `Spot` constructor
- `getHookPermissions()`: return the combined mask enabling `afterInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`
- `_beforeSwap(...)`: override to integrate discounting; compute `effectiveFee` and use it everywhere the dynamic fee is used in `Spot`
- Do not override `_afterSwap(...)` or `_afterInitialize(...)` (unless you need minor Brevis-specific checks); rely on `Spot` behavior
- Preserve all Brevis admin and callback functions and `init(...)`

### VipDiscountMap.sol and BrevisApp.sol – unchanged

- Keep existing APIs and internal update flow
- Optional: add a helper to compute discounted fees given a base; in the hook, the logic is straightforward and can be inlined

### Deployment scripts

- Update permission bits to `0xCC2`
- Deploy implementation with AEGIS addresses in the constructor
- Deploy proxy via CREATE2 to match the permission suffix
- Immediately call `init(owner, initialVk)` on the proxy
- Authorize the proxy in FRLM

---

## Risks and considerations

- **Storage and upgrade safety**: Inheritance ordering preserves storage layout. However, additional callbacks require a new address with encoded permissions; prefer fresh deployment for pools needing dynamic fees.
- **Multiple admin roles**: Separate Brevis admin (`Ownable`) and AEGIS policy owner (`PoolPolicyManager.owner()`). Coordinate governance actions.
- **Performance**: Minimal additional gas (a mapping read and simple math). Dominated by dynamic fee/oracle ops.
- **Security**: Discount cannot create negative fees; arithmetic is bounded. Using `tx.origin` mirrors Brevis assumptions and trade-offs. Ensure prompt proxy initialization.

---

## Compatibility with AEGIS modules

- `DynamicFeeManager`: Initialization in `afterInitialize`; ongoing observations/cap notifications post-swap
- `FullRangeLiquidityManager` (FRLM): Authorize the hook proxy address; notify on fee mint events; reinvest via `Spot`
- `PoolPolicyManager` and oracle: Interact as in `Spot`; unchanged

---

## Testing and validation

- **Unit tests**:
  - Swaps with: no discount, VIP discount, manual fee override, surge fee active
  - Verify user pays less under discount; protocol fee scales accordingly for both exact-in and exact-out
  - Confirm fee override equals discounted dynamic fee each swap
- **Oracle/manager updates**: Observe oracle writes and dynamic fee state transitions post-swap
- **Discount updates**: Exercise `brevisBatchCallback` to update discounts and verify application; enforce `onlyBrevisRequest`
- **Upgrade test**: Migrate logic while preserving storage; confirm pre-set discounts persist (permission bits caveat still applies for callbacks)
- **Edge cases**: 0% and 100% discounts; max surge and manual fee; reinvestment paused/unpaused

---

## Reference snippets

### Contract declaration and constructor (shape)

```solidity
contract VipHook is VipDiscountMap, BrevisApp, Spot, Ownable {
    constructor(
        IPoolManager _poolManager,
        IFullRangeLiquidityManager _liqManager,
        PoolPolicyManager _policyManager,
        ITruncGeoOracleMulti _oracle,
        IDynamicFeeManager _feeManager
    ) Spot(_poolManager, _liqManager, _policyManager, _oracle, _feeManager) {}

    // init(owner, initialVk, brevisRequest, baseFee) via proxy
}
```

### Discount application helper

```solidity
function _applyBrevisDiscount(uint24 baseFee, address trader) internal view returns (uint24) {
    uint16 discountBps = feeDiscount[trader].pctX100;
    if (discountBps == 0) return baseFee;
    return uint24(uint256(baseFee) * (10000 - discountBps) / 10000);
}
```

---

## References

- Brevis VIP Discount Hook System – Specification and Security Review (1)
  - `file://file-781H8tmw5HGTeAutJ2gctB`
- AEGIS Hook design notes
  - `file://file-DqB9AUpdQ2emcVXiKxx92q`
- `Spot.sol` (AEGIS): [Source link](https://github.com/labs-solo/Aegis-V2/blob/bbcdbc51801bc10466e09125bd79749cee3b28bf/src/Spot.sol)
