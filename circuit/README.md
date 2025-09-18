# Brevis VIP Fee discount circuit
constants that can be adjusted to fit different needs. Note values will be limited by total ZK circuit constraints.
```go
const (
	MaxReceipts = MaxPerUsr * MaxUsrNum
	MaxPerUsr   = 128
	MaxUsrNum   = 32
	TierNum     = 5
)
```

UniVipHookCircuit struct holds necessary info for one pool and users in the same batch
```go
type UniVipHookCircuit struct {
	Epoch sdk.Uint32  // unique identifier for one batch to avoid replay
	// contract addr that emits events. PoolAddr is PoolManager for Uniswap v4, HookAddr is create2 deployed Brevis Hook for this pool id
	PoolAddr, HookAddr sdk.Uint248
	// unique pool identifier, hash of PoolKey
	PoolId sdk.Bytes32
	// block range, check receipt is in range
	BlockStart, BlockEnd sdk.Uint32

	// tier configs
	// MUST be sorted from LOWEST to HIGHEST, discount must match minAmount config
	// logic is simple: disc = 0; while vol > minAmount[i], disc = dicount[i],
	TierMinAmount, TierDiscount [TierNum]sdk.Uint248

	// User addresses of one batch, same addr must be adjacent for vol to be added together
	Users [MaxUsrNum]sdk.Uint248
}
```

Brevis system will prepare receipts into batches. If one user has more than `MaxPerUsr` swaps, same user address will appear multiple times consecutively in the Users array.

Brevis Hook contract emits `event TxOrigin(address indexed addr)` to identify the user. Each receipt includes swap and txorigin event. The circuit will check event contract, block number etc are expected.

## Compute trading volume
Receipts are split segments by users, eg. receipts[0:MaxPerUsr-1] are for user[0] and so on. Circuit will add absolute value of swap amount to total trading volume of user[i]. Then we go over user array, if user[i] equals user[i-1], trading volume[i-1] will be added to trading volume[i]

## Decide fee discount
For each user's trading volume, go over all configered VIP tiers, if volume is greater than the minimum required volume of this tier, set discount to this tier, otherwise keep discount the same.

## Output
circuit outputs epoch:[address:discount] 
