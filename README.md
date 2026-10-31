# Morpheus DepositPool: lockClaim() prices the lock multiplier from the original stake date

Foundry proof of concept for a reward-weight inflation bug in the Morpheus
capital protocol. `lockClaim()` reuses the `claimLockStart` stored when the
position was first staked, so a position that sat unlocked for a long time
converts its entire age into lock multiplier weight while committing to only
a short new lock. A fresh staker locking the same capital for the same period
gets no such weight.

## Run

Requires Foundry. The test forks Ethereum mainnet at block 26,314,439, so it
needs an RPC endpoint that serves archive state at that block. It defaults to
a public dRPC endpoint that does; if you have your own archive RPC, point the
test at it with an environment variable:

```
forge test
# or:
ETH_RPC_URL=<your archive RPC> forge test
```

Other public endpoints verified to pass this test at the pinned block:
`https://eth-mainnet.public.blastapi.io` and `https://eth-pokt.nodies.app`.
(PublicNode's free endpoint intermittently refuses archive requests at this
block, which is why it is not the default.)

One test, `test_AgedPositionLockClaimInflatesWeight`, in
`test/LockClaimRetroReal.t.sol`. Expected: PASS (gas 1,218,918).

## What the test does

Fork: Ethereum mainnet block 26,314,439 (2026-10-31), stETH DepositPool
`0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790` (Appendix A of the Morpheus bug
bounty program).

1. Reads a real position on that pool: `0x357B2b095461A6f25F2D3E709b2a8830b71C0e1b`,
   3.9999 stETH deposited, `claimLockStart` 626 days before the fork block,
   never claimed, not locked (its `claimLockEnd` is in the past). Multiplier
   before: 1.01x (referral component only). Virtual stake: 4.0399 stETH.
2. The position owner calls `lockClaim(0, now + 30 days)`, committing to 30
   further days of claim lock and adding no capital.
3. Measured after: multiplier 3.7154x, virtual stake 14.8612 stETH. The
   position gained 10.8213 stETH of reward weight, and its share of the
   pool's reward stream rose from 0.0372% to 0.1368%.
4. Control: a fresh account stakes 4 stETH (obtained through Lido's public
   `submit()`) with the same 30-day lock end. Its multiplier is exactly 1.0x
   and its virtual stake is 4.0 stETH.

Assertions: the aged position's multiplier at least doubles; its virtual
stake is at least 1.5x the honest control's for identical capital and lock
terms; and the pool's `totalVirtualDeposited` grows by exactly the inflated
amount plus the control's stake, proving the new weight appears from nothing
and dilutes the fixed reward stream shared by all stakers.

## Accounts used

No privileged account is impersonated. The aged address is an ordinary
staker acting on its own position, which is the threat model: any staker
with an old unlocked position can do this today. The control account is a
fresh test address funded inside the test. No owner, admin, multisig, or
protocol account is pranked. No time travel and no mocked contracts: every
number above is mainnet state at the pinned block plus one real `lockClaim`
call.

## Root cause

In the verified implementation (`0xdB10dAEF167eA2233Ba6811457dD24D676FbD670`,
shared by all five DepositPool proxies):

- `DepositPool._stake()` writes `claimLockStart = block.timestamp`
  unconditionally, including for stakes with no lock at all, where
  `claimLockEnd == claimLockStart` and the committed lock period is zero.
- `DepositPool.lockClaim()` (line 323) then reuses that stored start:
  `claimLockStart_ = userData.claimLockStart > 0 ? userData.claimLockStart : uint128(block.timestamp)`,
  and `LockMultiplierMath` prices the whole `[start, end]` span.
- `_stake()` itself prices new stakes from `block.timestamp` (line 385), so
  the retroactive pricing is specific to `lockClaim()`.

Fix: price the `lockClaim()` multiplier from `block.timestamp`, as `_stake()`
does, and store that as the new `claimLockStart`.
