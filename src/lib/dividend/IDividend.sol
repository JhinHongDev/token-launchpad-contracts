// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @notice Interface for the Dividend distribution contract
interface IDividend {
    // --- Events ---
    /// @notice Emitted when a user's share is updated
    /// @param taxToken The tax token contract address
    /// @param user The user whose share was changed
    /// @param newShare The new share amount for the user
    /// @param totalShares The total shares after the change
    event FlapDividendShareChanged(
        address indexed taxToken, address indexed user, uint256 newShare, uint256 totalShares
    );

    /// @notice Emitted when dividends are deposited into the contract
    /// @param taxToken The tax token contract address
    /// @param amount The amount of dividend tokens deposited
    /// @param magnifiedDividendPerShare The updated magnified dividend per share
    event FlapDividendDeposited(address indexed taxToken, uint256 amount, uint256 magnifiedDividendPerShare);

    /// @notice Emitted when dividends are distributed to a user
    /// @param taxToken The tax token contract address
    /// @param user The user who received the dividends
    /// @param amount The amount of dividends distributed
    event FlapDividendDistributed(address indexed taxToken, address user, uint256 amount);

    /// @notice Emitted when an address is excluded from receiving dividends
    /// @param taxToken The tax token contract address
    /// @param addr The address that was excluded
    event FlapDividendAddressExcluded(address indexed taxToken, address addr);

    /// @notice Emitted when an address is removed from the exclusion list
    /// @param taxToken The tax token contract address
    /// @param addr The address that was unexcluded
    event FlapDividendAddressUnexcluded(address indexed taxToken, address addr);

    /// @notice Emitted when a dividend withdrawal fails
    /// @param taxToken The tax token contract address
    /// @param user The user for whom the withdrawal failed
    /// @param amount The amount that failed to be withdrawn
    event FlapDividendWithdrawalFailed(address indexed taxToken, address user, uint256 amount);

    /// @notice Emitted when a user's pending balance changes
    /// @param taxToken The tax token contract address
    /// @param user The user whose pending balance changed
    /// @param pendingBalance The new pending balance
    event FlapDividendPendingBalanceChanged(address indexed taxToken, address indexed user, uint256 pendingBalance);

    /// @notice Emitted when a user's reward debt changes
    /// @param taxToken The tax token contract address
    /// @param user The user whose reward debt changed
    /// @param rewardDebt The new reward debt
    event FlapDividendRewardDebtChanged(address indexed taxToken, address indexed user, uint256 rewardDebt);

    /// @notice Emitted when a first-time receiver's share write is skipped because the
    ///         transaction's `tx.origin` is in `deferredOrigins`.
    /// @dev The transfer SUCCEEDS; only the dividend registration is outstanding. The
    ///      keeper must call `refreshShares` to settle it. Until then the holder's share is 0
    ///      and they accrue nothing — but their slice is held back from other holders via
    ///      until the keeper settles them.
    /// @param taxToken The tax token contract address
    /// @param user The holder whose registration was deferred
    /// @param share The share that would have been written
    /// @param origin The `tx.origin` that triggered the deferral
    event FlapDividendShareDeferred(
        address indexed taxToken, address indexed user, uint256 share, address indexed origin
    );

    /// @notice Emitted when an origin is added to or removed from the deferral set.
    event FlapDividendDeferredOriginSet(address indexed taxToken, address indexed origin, bool deferred);

    /// @notice Emitted when an address is added to or removed from the `refreshShares`
    ///         keeper set.
    event FlapDividendKeeperSet(address indexed taxToken, address indexed keeper, bool allowed);

    /// @notice Emitted when a holder's dividend payout destination is changed by the owner.
    /// @dev `previousReceiver` is included so a monitor can alert on redirects without
    ///      keeping its own state. address(0) in either field means "no redirect".
    event FlapDividendReceiverSet(
        address indexed taxToken, address indexed holder, address indexed receiver, address previousReceiver
    );

    /// @notice Emitted when the dividend token is updated
    /// @param taxToken The tax token contract address
    /// @param oldToken The previous dividend token address
    /// @param newToken The new dividend token address
    event FlapDividendTokenUpdated(address indexed taxToken, address indexed oldToken, address indexed newToken);

    // --- Immutable / Storage Accessors ---

    /// @notice WETH address (if dividendToken == weth, native ETH is sent on withdraw)
    function weth() external view returns (address);

    /// @notice FlapBlackHole address (always excluded from dividends)
    function flapBlackHole() external view returns (address);

    /// @notice The ERC-20 token distributed as dividends
    function dividendToken() external view returns (address);

    /// @notice The FlapTaxToken that is allowed to call setShare
    function taxToken() external view returns (address);

    /// @notice Current magnified dividend per share accumulator
    /// @dev Non-zero means dividends have been deposited under the current token;
    ///      must be 0 before changing dividendToken to avoid accounting corruption.
    function getMagnifiedDividendPerShare() external view returns (uint256);

    /// @notice Per-user info snapshot (share, rewardDebt, pendingBalance)
    /// @param user The user address
    /// @return share        Current share / stake
    /// @return rewardDebt   Accumulator offset already credited to the user
    /// @return pendingBalance Settled rewards not yet claimed
    function userInfo(address user) external view returns (uint256 share, uint256 rewardDebt, uint256 pendingBalance);

    /// @notice Total dividends that have been deposited and distributed
    function totalDividendsDistributed() external view returns (uint256);

    /// @notice Whether an address is excluded from receiving dividends
    /// @param addr The address to query
    function excludedFromDividends(address addr) external view returns (bool);

    /// @notice Remove an address from the exclusion list
    /// @param addr The address to unexclude
    function unexcludeAddress(address addr) external;

    /// @notice Update the minimum share balance threshold
    /// @param newMin The new minimum share balance
    function setMinimumShareBalance(uint256 newMin) external;

    /// @notice Currently claimable amount for a user (does not include already withdrawn)
    /// @param user The user address
    function withdrawableDividendOf(address user) external view returns (uint256);

    /// @notice Lifetime earnings for a user (claimable + already withdrawn)
    /// @param user The user address
    function accumulativeDividendOf(address user) external view returns (uint256);

    /// @notice Initialize the dividend contract
    /// @param dividendToken_ The token used for dividend payments
    /// @param taxToken_ The tax token contract address
    /// @param minimumShareBalance_ The minimum balance required for dividend eligibility
    function initialize(address dividendToken_, address taxToken_, uint256 minimumShareBalance_) external;

    /// @notice Set user's share (only callable by FlapTaxToken)
    /// @param user The user address
    /// @param share The new share amount for the user
    function setShare(address user, uint256 share) external;

    /// @notice Deposit dividends to be distributed
    /// @param amount The amount of dividend tokens to deposit
    /// @return success Whether the deposit was successful
    function deposit(uint256 amount) external returns (bool success);

    /// @notice Batch distribute dividends to specified users
    /// @param users Array of user addresses to distribute dividends to
    /// @return successCount Number of successful distributions
    function distributeDividend(address[] calldata users) external returns (uint256 successCount);

    /// @notice User can call this to withdraw their own dividends (unwraps WETH to ETH if applicable)
    /// @return success Whether the withdrawal was successful
    function withdrawDividends() external returns (bool success);

    /// @notice Withdraw dividends for a specific user
    /// @param user The user address to withdraw for
    /// @return success Whether the withdrawal was successful
    function withdrawDividendsFor(address user) external returns (bool success);

    /// @notice Withdraw dividends for a specific user with option to unwrap WETH
    /// @param user The user address to withdraw for
    /// @param unwrapWETH Whether to unwrap WETH to ETH
    /// @return success Whether the withdrawal was successful
    function withdrawDividendsFor(address user, bool unwrapWETH) external returns (bool success);

    /// @notice Get the withdrawable dividend amount for a user
    /// @param user The user address
    /// @return The amount of dividends the user can claim
    function withdrawableDividends(address user) external view returns (uint256);

    /// @notice Exclude an address from receiving dividends
    /// @param addr The address to exclude
    function excludeAddress(address addr) external;

    /// @notice Get total shares across all users
    /// @return The total amount of shares
    function totalShares() external view returns (uint256);

    /// @notice Get the minimum share balance required for dividend eligibility
    /// @return The minimum share balance
    function minimumShareBalance() external view returns (uint256);

    /// @notice Get total dividends withdrawn by a user
    /// @param user The user address
    /// @return The total amount of dividends withdrawn
    function withdrawnDividends(address user) external view returns (uint256);

    /// @notice Emergency withdraw function to recover tokens in case of emergency
    /// @param token The token address to withdraw (use address(0) for native ETH)
    /// @param amount The amount to withdraw (0 means withdraw all)
    /// @param to The address to send the tokens to
    function emergencyWithdraw(address token, uint256 amount, address to) external;

    /// @notice Update the dividend token address
    /// @dev Only callable by the owner (Portal). Any undistributed dividends accrued
    ///      under the previous token should be distributed (or recovered via emergencyWithdraw)
    ///      before calling this function, as the accounting will switch to the new token immediately.
    /// @param newToken The new token to distribute as dividends (must be non-zero)
    function setDividendToken(address newToken) external;
}
