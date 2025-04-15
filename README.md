# Uniswap v4 Hook by Brevis
- beforeSwap hook with dynamic fee based on zk-verified trading volume

## Workflow
### [on Brevis] Configure and deploy hook contract
- Authenticate with Brevis frontend
- Fill form about hook details, eg. VIP tiers trading volume and discount percentage
- Submits form then Brevis backend will deploy hook contract and return hook contract address
### [on Uniswap v4] Setup Pool
- Initialize pool with PoolKey struct, including hooks address from previous step, and PoolKey.fee must be set to ​ ‌LPFeeLibrary.DYNAMIC_FEE_FLAG(or ‌0x800000)
- Save poolID, needed to link to deployed hook on Brevis
### [on Brevis] Link hook to pool and fund proving
- Associate hook address with poolID, note one hook can only be associated with one pool
- Call Brevis fee collector contract `fund(PoolId id) payable`, to deposit native gas token as proving fee. For each pool, proofs will only be generated when fee contract has enough balance for it
### [Brevis prover network] Generate and submit proof
- For each configured pool, Brevis system will query all swap events during predefined time window(eg. past 30 days), grouped by user (defined as tx.origin address)
- For each user’s swaps, total trading volume is calculated. Then fee discount percentage is determined based on the volume and hook config
- Brevis generates zk-proof for the result and submit onchain. Note to improve efficiency, multiple users will be batched in one onchain tx
- After Brevis core contract validates proof, results are passed to hook contract which decodes and saves user address => fee discount internally
### [on Uniswap v4] User swap
- Frontend can query Brevis server for the user’s VIP tier and discounted fee on a list of pools, and compute optimal swap path
- For swap on each pool that has been configured with Brevis, beforeSwap hook will be triggered. The hook contract will compute a new fee based on fee discount and return
 (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
- If the user is not qualified for any discount, the originally configured fee will apply.