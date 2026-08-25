// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

// Vendored verbatim from flap.sh production (BSC 0x0e7Effa4fb7C528BBc65296f9A7580b3a63Df9C5, MIT).
// Only the import paths below were adjusted to this repository's layout; logic is byte-identical.
import "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IDividend} from "./IDividend.sol";

interface IWETH {
    function withdraw(uint256) external;
}

/// @title Dividend Distribution Contract
/// @notice MasterChef-style dividend distribution based on share proportions
/// @dev Implements precise dividend calculation using magnified dividend per share.
///
///      OVERFLOW SAFETY ON THE TRANSFER PATH
///      ------------------------------------
///      `setShare` runs on every token transfer, and every call site wraps it in
///      try/catch only to re-`revert DividendShareUpdateFailed(...)` (TokenV3
///      `_afterTokenTransfer`, FlapTaxTokenV{2,3}). An arithmetic revert inside
///      `setShare` therefore does not degrade gracefully — it makes the token
///      non-transferable for the affected holder. The invariant to hold is:
///
///          setShare MUST NOT revert for any share an ERC-20 balance can hold,
///          at any reachable value of `magnifiedDividendPerShare` (mdps).
///
///      The threat is `rewardDebt = ceilDiv(share * mdps, MAGNITUDE)`. The inner
///      product overflows uint256 once `share * mdps >= 2**256`, and mdps grows by
///      `amount * MAGNITUDE / totalShares` per deposit — so it inflates without bound
///      when dividends are deposited while `totalShares` sits near its floor
///      (`minimumShareBalance`) and a holder later accumulates a large share. A token
///      paying dividends in itself at a large supply reaches that corner.
///
///      Fixed by computing every `share * mdps / MAGNITUDE` through
///      `FixedPointMathLib.fullMulDiv{,Up}`, which carries a 512-bit intermediate and
///      only reverts if the true quotient exceeds uint256. Since
///      `quotient = share * mdps / 2**128` and mdps is itself a uint256 (`< 2**256`),
///      `share < 2**128` is sufficient for `quotient < 2**256`. An ERC-20 balance
///      below 2**128 (3.4e38) therefore cannot revert here, whatever mdps does —
///      that is 3.4e5x a 1e33-wei (1e15-token) supply.
///
///      mdps itself is a plain checked accumulator, so a pathological deposit reverts
///      inside `deposit()` rather than corrupting later `setShare` calls. Reaching
///      that needs cumulative `amount * 2**128 / totalShares >= 2**256`, i.e. ~1e60
///      wei of dividends at the `minimumShareBalance` floor.
///
///      Storage widths are unchanged: `UserInfo` is still three `uint256`s.
///      Covered by test/Dividend.BigSupply.t.sol (1e33 supply, self-dividend).
contract Dividend is IDividend, OwnableUpgradeable {
    // --- Constants ---
    uint256 internal constant MAGNITUDE = 2 ** 128;

    // --- Immutable Storage ---
    /// @notice WETH address (if dividendToken == weth, we send native ETH)
    address public immutable weth;

    /// @notice FlapBlackHole address (excluded from dividends)
    address public immutable flapBlackHole;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address weth_, address flapBlackHole_) {
        require(weth_ != address(0), "Dividend: zero WETH address");
        weth = weth_;
        flapBlackHole = flapBlackHole_;
        _disableInitializers();
    }

    // --- Storage ---
    /// @notice The token used for dividend distribution.
    /// @dev This can be any ERC-20: the quote token, the tax token itself, or an unrelated token.
    ///      The front-end MUST read this field to determine which token is being distributed
    ///      rather than assuming a fixed token type.
    ///      This is never the zero address; when the dividend is the native gas token,
    ///      WETH is used instead and unwrapped to ETH upon withdrawal.
    address public dividendToken;

    /// @notice The FlapTaxToken contract that can call setShare
    address public taxToken;

    /// @notice User info structure combining share, debt, and pending balance
    struct UserInfo {
        uint256 share; // User's share amount
        uint256 rewardDebt; // Reward debt (already claimed debt)
        uint256 pendingBalance; // Pending balance (settled rewards before share changes)
    }

    /// @notice Magnified dividend per share for precise calculation
    uint256 internal magnifiedDividendPerShare;

    /// @notice Total shares across all users
    uint256 public totalShares;

    /// @notice Mapping of user address to their info
    mapping(address => UserInfo) public userInfo;

    /// @notice Total dividends withdrawn by each user
    mapping(address => uint256) public withdrawnDividends;

    /// @notice Total dividends distributed
    uint256 public totalDividendsDistributed;

    /// @notice Minimum share balance required for dividend distribution
    uint256 public minimumShareBalance;

    /// @notice Addresses excluded from receiving dividends
    mapping(address => bool) public excludedFromDividends;

    // --- Deferred first-receive registration ---
    //
    // WHY THIS EXISTS
    // ---------------
    // `setShare` runs on every transfer. A first-time receiver, once dividends are
    // flowing (mdps != 0), takes both `share` and `rewardDebt` from zero to non-zero:
    // two SSTORE_SET, ~44_200 cold. Some callers forward too little gas for that, and
    // every call site re-reverts on failure (TokenV3._afterTokenTransfer), so the whole
    // transfer dies rather than degrading.
    //
    // For origins in `deferredOrigins`, the first-receive write is skipped and an event
    // is emitted for the keeper to settle later.
    //
    // ACCEPTED COST: THE DEFERRAL WINDOW IS UNPAID
    // --------------------------------------------
    // A deferred holder has share 0, so they are absent from `totalShares`. Any deposit
    // landing before the keeper settles them is divided among the other holders and is
    // immediately claimable by those holders. The later sync recovers none of it — it
    // books `rewardDebt` at the then-current mdps. So the window is a forfeit, not a
    // delay. Measured in test/Dividend.Forfeiture.t.sol: with two equal holders, one
    // deferred, the incumbent takes 100% of a window deposit instead of 50%.
    //
    // This is deliberate. Holding the slice back would need the deferred amount tracked
    // per holder so the deposit denominator could include it, and that per-holder slot is
    // itself an SSTORE_SET on the exact path whose purpose is to avoid one — it would cost
    // most of what deferral saves, and it adds several states where the tracking can
    // diverge from reality.
    //
    // The mitigation is operational, not on-chain: the keeper settles promptly, so no
    // deposit lands inside the window. Exposure per incident is bounded by
    // (deposits during the window) x (deferred holder's share of the pool). Keeper latency
    // is therefore a financial parameter, not just a liveness one.
    //
    // A deferred holder also self-heals without the keeper: their next transfer calls
    // `setShare` again, and if that transaction's origin is not deferred, the share is
    // written inline.

    /// @notice Origins whose first-receive share write is deferred to the keeper.
    /// @dev Keyed on `tx.origin`. Not an authorisation check — `tx.origin` is used purely
    ///      as an unforgeable identifier for the EOA that signed the transaction, which is
    ///      the only caller identity visible here (Dividend always sees `msg.sender` ==
    ///      taxToken). The usual `tx.origin` warning applies to
    ///      `require(tx.origin == owner)` style authorisation, which this is not.
    ///
    ///      Chosen over a `gasleft()` threshold because a gas-based branch makes
    ///      `eth_estimateGas` converge on the cheaper deferred path: its binary search
    ///      finds the lowest limit that succeeds, and deferral succeeds at a lower limit,
    ///      so wallets would send exactly enough gas to trigger deferral and it would
    ///      become the default path rather than the exception. An origin-keyed branch does
    ///      not vary with gas, so estimation converges on the real cost.
    mapping(address => bool) public deferredOrigins;

    /// @notice Addresses (besides `owner`) permitted to call `refreshShares`.
    /// @dev `refreshShares` re-derives `share` from the tax token's live `balanceOf`, so a
    ///      caller cannot install an arbitrary value — but the caller DOES choose *which*
    ///      address's `share == 0 -> share == balanceOf` transition happens and in *which
    ///      block*. For an address that was never legitimately deferred (e.g. a liquidity
    ///      pair the owner has not yet called `excludeAddress` on), that choice lets a
    ///      caller register a large balance as dividend shares at a moment of their
    ///      choosing, immediately ahead of a `deposit()` they control. Restricting the
    ///      caller to `owner`/trusted keepers closes that path without touching `setShare`,
    ///      which must stay free of any new cold storage write on the deferred branch (see
    ///      the OOG replay in test/Dividend.OOGReplay.BSC.fork.t.sol).
    mapping(address => bool) public keepers;

    /// @dev Payout redirect: dividends earned by the key are sent to the value.
    ///      address(0) means no redirect — pay the holder directly. Read via `receiverOf`.
    ///
    ///      Only the payout destination changes. `share`, `rewardDebt`, `pendingBalance`
    ///      and `withdrawnDividends` all stay keyed on the holder, so accounting is
    ///      unaffected and `withdrawableDividendOf(holder)` keeps its meaning.
    ///
    ///      OWNER-SET, BY DESIGN. The owner can redirect any holder's dividends with no
    ///      notice to that holder and no way for them to refuse. Every change emits
    ///      `FlapDividendReceiverSet` with the previous value, so it is observable
    ///      on-chain — but observable is not preventable. Make the owner a timelock or
    ///      multisig if that authority needs constraining; that is a deployment choice
    ///      and needs no change here.
    mapping(address => address) internal _dividendReceiver;

    function _isExcluded(address user) internal view returns (bool) {
        return _isExcluded(user, taxToken);
    }

    /// @dev Overload for callers that already hold `taxToken` in a local, so the check
    ///      does not pay a second SLOAD for it.
    function _isExcluded(address user, address taxToken_) internal view returns (bool) {
        return user == address(0) || user == address(0xdead) || user == address(this) || user == taxToken_
            || user == flapBlackHole || excludedFromDividends[user];
    }

    /// @dev `share * mdps / MAGNITUDE`, rounded down. 512-bit intermediate: cannot
    ///      overflow for `share < 2**128`. See the OVERFLOW SAFETY note on the contract.
    function _accruedFor(uint256 share, uint256 mdps) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(share, mdps, MAGNITUDE);
    }

    /// @dev `share * mdps / MAGNITUDE`, rounded up — the `rewardDebt` a holder is booked
    ///      at. Rounding up prevents holders from accumulating claimable dust.
    ///      Same 512-bit intermediate as `_accruedFor`.
    function _debtFor(uint256 share, uint256 mdps) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDivUp(share, mdps, MAGNITUDE);
    }

    // --- Initialization ---
    function initialize(address dividendToken_, address taxToken_, uint256 minimumShareBalance_) external initializer {
        require(dividendToken_ != address(0) && taxToken_ != address(0), "Dividend: zero init arg");

        __Ownable_init();

        dividendToken = dividendToken_;
        taxToken = taxToken_;
        minimumShareBalance = minimumShareBalance_;

        // No need to exclude addresses during initialization
        // Exclusion logic will be handled in setShare method or by the calling contract
    }

    // --- External Functions ---

    /// @notice Set user's share (only callable by FlapTaxToken)
    /// @param user The user address
    /// @param share The new share amount for the user
    function setShare(address user, uint256 share) external {
        // Read taxToken once and reuse it for the caller check, the exclusion check and
        // the events emitted downstream.
        address taxToken_ = taxToken;
        require(msg.sender == taxToken_, "Dividend: caller is not the tax token");

        // Skip excluded addresses to save gas (hardcoded exclusions + mapping-based exclusions)
        if (_isExcluded(user, taxToken_)) return;
        // If share is below minimum threshold, set to 0
        if (share < minimumShareBalance) {
            share = 0;
        }

        // --- deferral gate ---
        //
        // ONLY a first receive may defer: currentShare == 0 && share > 0.
        //
        // A decrease must NEVER defer. If it did, a seller would keep their share after
        // selling and keep earning on tokens they no longer hold — and a flash loan turns
        // that into a direct drain: borrow, register a large share, trigger a taxed swap
        // that calls deposit(), sell (decrease deferred, share intact), then keep taking a
        // cut of every later deposit. This condition is the load-bearing safety property
        // of the whole mechanism.
        //
        // While mdps == 0 there is nothing to lose by writing inline (rewardDebt stays 0,
        // so it is a single SSTORE_SET), so do not defer then either.
        uint256 currentShare = userInfo[user].share;
        if (currentShare == 0 && share > 0 && magnifiedDividendPerShare != 0) {
            // Read the origin flag only on the path that can actually defer, so ordinary
            // transfers do not pay for the cold SLOAD.
            if (deferredOrigins[tx.origin]) {
                // No storage write at all: the event is the entire record, and the
                // off-chain keeper is the only consumer. Emitting unconditionally (rather
                // than deduplicating on a stored marker) keeps this path free of
                // SSTORE_SET, which is the whole point; a repeat emission for the same
                // holder is harmless because `refreshShares` re-reads `balanceOf` and is
                // idempotent.
                emit FlapDividendShareDeferred(taxToken_, user, share, tx.origin);
                return;
            }
        }

        _setShare(user, share, taxToken_);
    }

    // --- Deferred registration: keeper settlement ---

    /// @notice Settle deferred first-receive registrations. Callable by `owner` or a
    ///         registered keeper (see `setKeeper`).
    /// @param users The holders to settle. Entries that are not pending are skipped.
    /// @dev The share is re-read from the tax token's `balanceOf` rather than taken from
    ///      the event or a parameter, so a wrong or malicious argument cannot install an
    ///      arbitrary share.
    ///
    ///      Idempotent: settling a holder twice is a no-op the second time.
    ///
    ///      RESTRICTED, NOT PERMISSIONLESS: this does not verify that a submitted address
    ///      was ever actually deferred, only that it is not excluded. For an address that
    ///      is not yet excluded but should be (e.g. a freshly created liquidity pair), an
    ///      unrestricted caller could pick the exact block in which that address's `share`
    ///      jumps from 0 to its live balance, immediately ahead of a `deposit()` they
    ///      control. Restricting the caller closes that path; see the `keepers` mapping
    ///      natspec for the full rationale.
    function refreshShares(address[] calldata users) external {
        require(msg.sender == owner() || keepers[msg.sender], "Dividend: not a keeper");
        address taxToken_ = taxToken;
        uint256 minShare = minimumShareBalance;

        for (uint256 i = 0; i < users.length; ++i) {
            address user = users[i];
            if (_isExcluded(user, taxToken_)) continue;

            // Re-read the live balance instead of trusting the event payload or a
            // caller-supplied number, so a wrong argument cannot install an arbitrary
            // share. Also makes this a general repair tool: works on any address whose
            // share has drifted from its balance, not just deferred ones.
            uint256 share = SafeTransferLib.balanceOf(taxToken_, user);
            if (share < minShare) share = 0;

            // `_setShare` returns early when unchanged, so re-syncing a correct holder
            // costs no write. Idempotent.
            _setShare(user, share, taxToken_);
        }
    }

    // --- Deferred registration: admin ---

    /// @notice Add or remove an origin from the deferral set.
    function setDeferredOrigin(address origin, bool deferred) external onlyOwner {
        require(origin != address(0), "Dividend: zero origin");
        deferredOrigins[origin] = deferred;
        emit FlapDividendDeferredOriginSet(taxToken, origin, deferred);
    }

    /// @notice Add or remove an address from the `refreshShares` keeper set.
    function setKeeper(address keeper, bool allowed) external onlyOwner {
        require(keeper != address(0), "Dividend: zero keeper");
        keepers[keeper] = allowed;
        emit FlapDividendKeeperSet(taxToken, keeper, allowed);
    }

    /// @notice Redirect a holder's dividend payouts to another address.
    /// @param holder The holder whose dividends are redirected
    /// @param receiver Destination, or address(0) to clear the redirect
    function setDividendReceiver(address holder, address receiver) external onlyOwner {
        require(holder != address(0), "Dividend: zero holder");
        address previous = _dividendReceiver[holder];
        _dividendReceiver[holder] = receiver;
        emit FlapDividendReceiverSet(taxToken, holder, receiver, previous);
    }

    /// @notice Where a holder's dividends are paid. Falls back to the holder themselves.
    function receiverOf(address holder) public view returns (address) {
        address r = _dividendReceiver[holder];
        return r == address(0) ? holder : r;
    }

    /// @notice Deposit dividends to be distributed
    /// @param amount The amount of dividend tokens to deposit
    /// @return success Whether the deposit was successful
    /// @dev Only accepts ERC20 tokens, returns false if no shares exist
    function deposit(uint256 amount) external returns (bool success) {
        if (amount == 0) {
            return false;
        }

        // Deferred holders are NOT in this denominator — they have share 0 until the keeper
        // settles them, so a deposit landing inside a deferral window is divided among the
        // remaining holders and is immediately claimable by them. The deferred holder's
        // slice is forfeited, not reserved, and a later refresh recovers none of it. That
        // is the accepted cost of deferral, measured in test/Dividend.Forfeiture.t.sol
        // (two equal holders, one deferred -> the other takes 100% of the window deposit).
        // Reserving it instead would need the deferred amount tracked per holder, which is
        // an SSTORE_SET on the exact path whose purpose is to avoid one.
        uint256 totalShares_ = totalShares;
        if (totalShares_ == 0) {
            return false; // No shareholders to distribute to
        }

        // Transfer dividend tokens (only ERC20).
        // Use balance-diff pattern to correctly account for tokens with transfer taxes.
        address token = dividendToken;
        uint256 balanceBefore = SafeTransferLib.balanceOf(token, address(this));
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 actualReceived = SafeTransferLib.balanceOf(token, address(this)) - balanceBefore;

        if (actualReceived == 0) {
            return false;
        }

        // Update magnified dividend per share based on what was actually received.
        // fullMulDiv keeps `actualReceived * MAGNITUDE` off the uint256 ceiling, so a
        // large-supply self-dividend deposit cannot revert here on the inner product.
        uint256 newMdps =
            magnifiedDividendPerShare + FixedPointMathLib.fullMulDiv(actualReceived, MAGNITUDE, totalShares_);
        magnifiedDividendPerShare = newMdps;

        totalDividendsDistributed = totalDividendsDistributed + actualReceived;

        emit FlapDividendDeposited(taxToken, actualReceived, newMdps);
        return true;
    }

    /// @notice Batch distribute dividends to specified users
    /// @param users Array of user addresses to distribute dividends to
    function distributeDividend(address[] calldata users) external returns (uint256 successCount) {
        successCount = 0;
        for (uint256 i = 0; i < users.length; i++) {
            if (_withdrawDividendOfUser(users[i], false)) {
                // false = distributeDividend mode (send WETH directly)
                successCount++;
            }
        }

        return successCount;
    }

    /// @notice User can call this to withdraw their own dividends (unwraps WETH to ETH if applicable)
    /// @return success Whether the withdrawal was successful
    function withdrawDividends() external returns (bool success) {
        return _withdrawDividendOfUser(msg.sender, true); // true = withdrawDividends mode (unwrap WETH if needed)
    }

    /// @notice Withdraw dividends for a specific user
    /// @param user The user address to withdraw for
    /// @return success Whether the withdrawal was successful
    function withdrawDividendsFor(address user) external returns (bool success) {
        return _withdrawDividendOfUser(user, true);
    }

    /// @notice Withdraw dividends for a specific user with option to unwrap WETH
    /// @param user The user address to withdraw for
    /// @param unwrapWETH Whether to unwrap WETH to ETH
    /// @return success Whether the withdrawal was successful
    function withdrawDividendsFor(address user, bool unwrapWETH) external returns (bool success) {
        return _withdrawDividendOfUser(user, unwrapWETH);
    }

    /// @notice Get the withdrawable dividend amount for a user
    /// @param user The user address
    /// @return The amount of dividends the user can claim
    function withdrawableDividends(address user) external view returns (uint256) {
        return withdrawableDividendOf(user);
    }

    /// @notice Exclude an address from receiving dividends
    /// @param addr The address to exclude
    function excludeAddress(address addr) external onlyOwner {
        require(!excludedFromDividends[addr], "Dividend: already excluded");
        excludedFromDividends[addr] = true;

        // Reset their share to 0
        if (userInfo[addr].share > 0) {
            _setShare(addr, 0);
        }

        emit FlapDividendAddressExcluded(taxToken, addr);
    }

    /// @notice Remove an address from the exclusion list so it can accumulate
    ///         shares again on future token transfers.
    function unexcludeAddress(address addr) external onlyOwner {
        require(excludedFromDividends[addr], "Dividend: address not excluded");
        delete excludedFromDividends[addr];
        emit FlapDividendAddressUnexcluded(taxToken, addr);
    }

    /// @notice Update the dividend token address
    /// @dev Only callable by the owner (Portal). Any undistributed dividends accrued
    ///      under the previous token should be distributed (or recovered via emergencyWithdraw)
    ///      before calling this function, as the accounting will switch to the new token immediately.
    /// @param newToken The new token to distribute as dividends (must be non-zero)
    function setDividendToken(address newToken) external onlyOwner {
        require(newToken != address(0), "Dividend: zero token address");
        require(magnifiedDividendPerShare == 0, "magnifiedDividendPerShare must be 0");
        address oldToken = dividendToken;
        dividendToken = newToken;
        emit FlapDividendTokenUpdated(taxToken, oldToken, newToken);
    }

    /// @notice Update the minimum share balance threshold
    /// @param newMinimumShareBalance The new minimum share balance
    function setMinimumShareBalance(uint256 newMinimumShareBalance) external onlyOwner {
        minimumShareBalance = newMinimumShareBalance;
    }

    // --- Public View Functions ---

    /// @notice Get the current magnified dividend per share accumulator
    /// @return The current magnifiedDividendPerShare value
    function getMagnifiedDividendPerShare() public view returns (uint256) {
        return magnifiedDividendPerShare;
    }

    /// @notice Get the withdrawable dividend for a user
    /// @param user The user address
    /// @return The withdrawable dividend amount (currently claimable)
    function withdrawableDividendOf(address user) public view returns (uint256) {
        UserInfo storage info = userInfo[user];

        // Part 1: (share * magnifiedDividendPerShare - rewardDebt) / MAGNITUDE
        uint256 accumulatedDividend = _accruedFor(info.share, magnifiedDividendPerShare);
        uint256 rewardDebt = info.rewardDebt;
        uint256 part1;
        if (accumulatedDividend > rewardDebt) {
            part1 = accumulatedDividend - rewardDebt;
        } else {
            part1 = 0;
        }

        // Part 2: pendingBalance (settled rewards from previous share changes)
        uint256 part2 = info.pendingBalance;

        // Total currently claimable = part1 + part2
        return part1 + part2;
    }

    /// @notice Get the cumulative dividend for a user (total ever earned)
    /// @param user The user address
    /// @return The cumulative dividend amount (includes withdrawn + withdrawable)
    function accumulativeDividendOf(address user) public view returns (uint256) {
        // Total earned = currently withdrawable + already withdrawn
        return withdrawableDividendOf(user) + withdrawnDividends[user];
    }

    // --- Internal Functions ---

    /// @notice Internal function to set a user's share
    /// @param user The user address
    /// @param newShare The new share amount
    function _setShare(address user, uint256 newShare) internal {
        _setShare(user, newShare, taxToken);
    }

    /// @notice Internal function to set a user's share
    /// @param user The user address
    /// @param newShare The new share amount
    /// @param taxToken_ `taxToken`, already loaded by the caller
    /// @dev When share changes, settle current claimable amount into pendingBalance.
    ///      Storage reads are hoisted into locals because this runs on every transfer:
    ///      `magnifiedDividendPerShare`, `totalShares` and `taxToken` were each read
    ///      two to four times per call.
    function _setShare(address user, uint256 newShare, address taxToken_) internal {
        UserInfo storage info = userInfo[user];
        uint256 currentShare = info.share;

        if (newShare == currentShare) {
            return;
        }

        uint256 mdps = magnifiedDividendPerShare;

        // INVARIANT: share == 0 implies rewardDebt == 0.
        // Every write to rewardDebt sets it to `ceilDiv(share * mdps, MAGNITUDE)` for the
        // share stored alongside it (here and in `_withdrawDividendOfUser`), and that is 0
        // whenever share is 0. So for a first-time receiver the `rewardDebt` SLOAD can be
        // skipped entirely — 2_100 gas off the most expensive path, which is exactly the
        // one that runs out of gas. Pinned by test/Dividend.ZeroShareInvariant.t.sol, which
        // covers all five paths that drive a share to zero plus a fuzzed interleaving.
        uint256 currentDebt = currentShare == 0 ? 0 : info.rewardDebt;

        // Settlement: calculate and store current claimable amount before changing share
        // This simulates claiming and adds to pendingBalance
        if (currentShare > 0) {
            uint256 accumulatedDividend = _accruedFor(currentShare, mdps);
            if (accumulatedDividend > currentDebt) {
                uint256 newPending = info.pendingBalance + (accumulatedDividend - currentDebt);
                info.pendingBalance = newPending;
                emit FlapDividendPendingBalanceChanged(taxToken_, user, newPending);
            }
        }

        // Update total shares
        uint256 newTotalShares;
        if (newShare > currentShare) {
            newTotalShares = totalShares + (newShare - currentShare);
        } else {
            newTotalShares = totalShares - (currentShare - newShare);
        }
        totalShares = newTotalShares;

        // Update user's share
        info.share = newShare;

        // Update rewardDebt to current accumulated amount for new share
        // This represents the "already claimed" debt for the new share amount
        uint256 newDebt = _debtFor(newShare, mdps);
        // While no dividends have been deposited yet (mdps == 0) the debt stays 0 for
        // every holder, so skip the store and the log instead of rewriting an unchanged
        // value on every transfer.
        if (newDebt != currentDebt) {
            info.rewardDebt = newDebt;
            emit FlapDividendRewardDebtChanged(taxToken_, user, newDebt);
        }

        emit FlapDividendShareChanged(taxToken_, user, newShare, newTotalShares);
    }

    /// @notice Internal function to withdraw dividends for a user
    /// @param user The user address
    /// @param shouldUnwrapWETH Whether to unwrap WETH to ETH (true for withdrawDividends, false for distributeDividend)
    /// @return success Whether the withdrawal was successful
    function _withdrawDividendOfUser(address user, bool shouldUnwrapWETH) internal returns (bool success) {
        address taxToken_ = taxToken;
        if (_isExcluded(user, taxToken_)) return false; // excluded addresses cannot claim

        UserInfo storage info = userInfo[user];
        uint256 share = info.share;
        uint256 currentDebt = info.rewardDebt;
        uint256 pending = info.pendingBalance;
        uint256 mdps = magnifiedDividendPerShare;

        // Same total as withdrawableDividendOf(user), computed from locals already loaded.
        uint256 accumulatedDividend = _accruedFor(share, mdps);
        uint256 withdrawableAmount = pending;
        if (accumulatedDividend > currentDebt) {
            withdrawableAmount += accumulatedDividend - currentDebt;
        }

        if (withdrawableAmount == 0) {
            return false;
        }

        // Update state: clear pendingBalance and update rewardDebt
        // Round up to prevent users from accumulating claimable dust after each withdrawal
        uint256 newDebt = _debtFor(share, mdps);
        if (newDebt != currentDebt) {
            info.rewardDebt = newDebt;
            emit FlapDividendRewardDebtChanged(taxToken_, user, newDebt);
        }
        if (pending != 0) {
            info.pendingBalance = 0;
            emit FlapDividendPendingBalanceChanged(taxToken_, user, 0);
        }

        withdrawnDividends[user] = withdrawnDividends[user] + withdrawableAmount;

        // Accounting above is all keyed on `user`; only the destination is redirected.
        // Note `_isExcluded` was checked against `user`, not the receiver — exclusion
        // governs who earns, not who may be paid, so an excluded receiver is fine.
        return _sendToken(user, receiverOf(user), withdrawableAmount, shouldUnwrapWETH);
    }

    /// @dev Transfer `amount` of dividendToken to `user`.
    ///      - If dividendToken == weth and unwrapWETH == true: unwrap WETH and send native ETH (reverts on failure)
    ///      - Otherwise: SafeTransferLib.safeTransfer (reverts atomically on failure, rolling back state changes)
    /// @param holder Who EARNED the dividend. Only used for the event, so `withdrawnDividends`
    ///        and `FlapDividendDistributed` stay keyed on the same address.
    /// @param receiver Where the tokens actually go — `receiverOf(holder)`.
    /// @dev The two are separate because a payout redirect must not change what the event
    ///      reports. Emitting the receiver would make any indexer that accumulates
    ///      per-holder payout attribute a redirected claim to the wrong address, and
    ///      `FlapDividendDistributed` is the only signal it has for that.
    function _sendToken(address holder, address receiver, uint256 amount, bool unwrapWETH) internal returns (bool) {
        address token = dividendToken;
        if (token == weth && weth != address(0) && unwrapWETH) {
            IWETH(weth).withdraw(amount);
            SafeTransferLib.safeTransferETH(receiver, amount);
        } else {
            // SafeTransferLib.safeTransfer handles all non-standard ERC20 variants:
            //   • No return value (USDT / TetherToken) : returndata.length == 0 → ok
            //   • Returns true   (standard ERC20)      : decoded true → ok
            //   • Returns false  (non-standard)        : reverts
            //   • Reverts                              : reverts
            // Reverting on failure is intentional: _withdrawDividendOfUser updates state
            // before calling _sendToken, so a revert here rolls back everything atomically,
            // leaving the user's pending balance intact to retry later.
            SafeTransferLib.safeTransfer(token, receiver, amount);
        }

        // Keyed on the holder, not the receiver: see the note on the parameters.
        emit FlapDividendDistributed(taxToken, holder, amount);
        return true;
    }

    /// @notice Emergency withdraw function to recover tokens in case of emergency
    /// @param token The token address to withdraw (use address(0) for native ETH)
    /// @param amount The amount to withdraw (0 means withdraw all)
    /// @param to The address to send the tokens to
    /// @dev Only callable by owner in emergency situations
    function emergencyWithdraw(address token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Dividend: invalid recipient");

        if (token == address(0)) {
            // Withdraw native ETH
            uint256 balance = address(this).balance;
            uint256 withdrawAmount = amount == 0 ? balance : amount;
            require(withdrawAmount <= balance, "Dividend: insufficient ETH balance");

            SafeTransferLib.safeTransferETH(to, withdrawAmount);
        } else {
            // Withdraw ERC20 token
            uint256 balance = SafeTransferLib.balanceOf(token, address(this));
            uint256 withdrawAmount = amount == 0 ? balance : amount;
            require(withdrawAmount <= balance, "Dividend: insufficient token balance");

            SafeTransferLib.safeTransfer(token, to, withdrawAmount);
        }
    }

    // --- Fallback ---
    /// @notice Allow contract to receive native ETH when unwrapping WETH
    receive() external payable {}
}
