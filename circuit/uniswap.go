package circuit

import (
	"encoding/hex"
	"fmt"

	"github.com/brevis-network/brevis-sdk/sdk"
)

const (
	MaxReceipts = MaxPerUsr * MaxUsrNum
	MaxPerUsr   = 128
	MaxUsrNum   = 32
	TierNum     = 5
)

// output addr:discount
type UniVipHookCircuit struct {
	Epoch sdk.Uint32
	// addr that emits events
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

const (
	UniSwapEv = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"
)

var (
	EventIdUniSwap = sdk.ParseEventID(Hex2Bytes(UniSwapEv))
	EventIdHook    = sdk.ParseEventID(Hex2Bytes("0x4f8272f9d756f2f56d6a05792b13469cba4d94669c54bf5b7014093a6af2a6a2"))
)

func (c *UniVipHookCircuit) Allocate() (maxReceipts, maxStorage, maxTransactions int) {
	return MaxReceipts, 0, 0
}

// each receipt has 3 logs, one and two are same swap from pool(poolid and amount0), one misc from hook(tx.origin)
// in.Receipts have MaxUsrNum segments, each seg has up to MaxPerUsr receipts
// first we sum each segment, then if Users[i] == Users[i+1], we add vol to later
func (c *UniVipHookCircuit) Define(api *sdk.CircuitAPI, in sdk.DataInput) error {
	api.AssertInputsAreUnique()

	api.OutputUint32(32, c.Epoch)
	receipts := sdk.NewDataStream(api, in.Receipts)
	// for each receipt, make sure it's from expected pool
	sdk.AssertEach(receipts, func(r sdk.Receipt) sdk.Uint248 {
		// Log index must be ascending order
		hookLog := r.Fields[0]
		swapLog := r.Fields[1]
		swapLog2 := r.Fields[2]

		return api.Uint248.And(
			// BlockStart < r.BlockNum < BlockEnd
			api.ToUint248(api.Uint32.And(
				api.Uint32.IsLessThan(c.BlockStart, r.BlockNum),
				api.Uint32.IsLessThan(r.BlockNum, c.BlockEnd),
				api.Uint32.IsEqual(swapLog.LogPos, swapLog2.LogPos)),
			),
			// swap addr and eventid
			api.Uint248.IsEqual(swapLog.Contract, c.PoolAddr),
			api.Uint248.IsEqual(swapLog2.Contract, c.PoolAddr),
			// poolid
			api.Bytes32.IsEqual(swapLog.Value, c.PoolId),
			// must be same event
			api.Uint248.IsEqual(swapLog.EventID, swapLog2.EventID),
			// eventid must equal uniswap
			api.Uint248.IsEqual(swapLog.EventID, EventIdUniSwap),

			// hook event
			api.Uint248.IsEqual(hookLog.Contract, c.HookAddr),
			api.Uint248.IsEqual(hookLog.EventID, EventIdHook),
		)
	})

	// usr trading vol
	totalVol := [MaxUsrNum]sdk.Uint248{}
	discount := [MaxUsrNum]sdk.Uint248{}
	for i := range MaxUsrNum {
		totalVol[i] = sdk.ConstUint248(0)
		discount[i] = sdk.ConstUint248(0)

		for j := range MaxPerUsr {
			r := in.Receipts.Raw[MaxPerUsr*i+j]
			amount := api.Int248.ABS(api.ToInt248(r.Fields[2].Value)) // swaplog2 value is amount
			usrAddr := api.ToUint248(r.Fields[0].Value)               // hookLog value is tx.origin addr
			totalVol[i] = api.Uint248.Select(
				api.Uint248.IsEqual(usrAddr, c.Users[i]),
				api.Uint248.Add(totalVol[i], amount),
				totalVol[i])
		}
	}
	// start from 2nd vol, if previous addr is the same, add prev to this
	// so if a user has 3 segments, last one has full total vol
	for i := 1; i < MaxUsrNum; i++ {
		totalVol[i] = api.Uint248.Select(
			api.Uint248.IsEqual(c.Users[i-1], c.Users[i]),
			api.Uint248.Add(totalVol[i], totalVol[i-1]),
			totalVol[i])
	}

	// decide discount based on vol, output addr and discount
	for i := range MaxUsrNum {
		for j := range TierNum {
			discount[i] = api.Uint248.Select(
				// if totalVol > tiermin, set discount to this tier, otherwise, keep discount unchanged
				api.Uint248.IsGreaterThan(totalVol[i], c.TierMinAmount[j]),
				c.TierDiscount[j],
				discount[i])
		}
		fmt.Println("account: ", c.Users[i], "total volume: ", totalVol[i])

		api.OutputAddress(c.Users[i])
		api.OutputUint(16, discount[i])
	}

	return nil
}

func DefaultUniCircuit() *UniVipHookCircuit {
	ret := &UniVipHookCircuit{
		PoolAddr:   sdk.ConstUint248(0),
		HookAddr:   sdk.ConstUint248(0),
		BlockStart: sdk.ConstUint32(0),
		BlockEnd:   sdk.ConstUint32(0),
		PoolId:     sdk.ConstFromBigEndianBytes(Hex2Bytes("0x0000000000000000000000000000000000000000000000000000000000000000")),
	}
	for i := range TierNum {
		ret.TierDiscount[i] = sdk.ConstUint248(0)
		ret.TierMinAmount[i] = sdk.ConstUint248(0)
	}
	for i := range MaxUsrNum {
		ret.Users[i] = sdk.ConstUint248(0)
	}
	return ret
}

// ===== utils =====
func Hex2Bytes(s string) (b []byte) {
	if len(s) >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
		s = s[2:]
	}
	// hex.DecodeString expects an even-length string
	if len(s)%2 == 1 {
		s = "0" + s
	}
	b, _ = hex.DecodeString(s)
	return b
}
