// SPDX-License-Identifier: MIT
pragma solidity 0.7.0;

import "./IERC20.sol";
import "./IMintableToken.sol";
import "./IDividends.sol";
import "./SafeMath.sol";

/**
 * @title Token
 * @notice ERC-20 token backed 1-to-1 by ETH, with on-chain dividend distribution.
 *
 * @dev Key design decisions:
 *   - Mint: caller deposits ETH and receives an equal amount of tokens.
 *   - Burn: caller redeems their entire token balance for the equivalent ETH,
 *           sent to any destination address they specify.
 *   - Holder list: maintained as a compact, ordered array.  An address is a
 *     "holder" when its token balance is strictly greater than zero.  Removal
 *     uses a swap-and-pop strategy (O(1)) to avoid gas-expensive array shifts.
 *   - Dividends: any caller may deposit ETH that is distributed proportionally
 *     to all current holders.  Accrued dividends are preserved even after a
 *     holder burns or transfers their tokens away.
 *   - Reentrancy safety: every function that makes an external ETH transfer
 *     follows the Checks-Effects-Interactions (CEI) pattern — all state is
 *     updated before the transfer is executed.
 */
contract Token is IERC20, IMintableToken, IDividends {
    // ------------------------------------------ //
    // ----- BEGIN: DO NOT EDIT THIS SECTION ---- //
    // ------------------------------------------ //
    using SafeMath for uint256;
    uint256 public totalSupply;
    uint256 public decimals = 18;
    string public name = "Test token";
    string public symbol = "TEST";
    mapping(address => uint256) public balanceOf;
    // ------------------------------------------ //
    // ----- END: DO NOT EDIT THIS SECTION ------ //
    // ------------------------------------------ //

    // -------------------------------------------------------------------------
    // ERC-20 allowance state
    // -------------------------------------------------------------------------

    /// @dev allowances[owner][spender] → approved amount.
    mapping(address => mapping(address => uint256)) private _allowances;

    // -------------------------------------------------------------------------
    // Holder-tracking state
    // -------------------------------------------------------------------------

    /**
     * @dev Packed ordered list of current token holders (non-zero balance).
     *      Slots are reused via swap-and-pop so removal is O(1).
     */
    address[] private _holders;

    /**
     * @dev 1-based position of each address in `_holders`.
     *      A value of 0 means the address is not currently a holder.
     */
    mapping(address => uint256) private _holderIndex;

    // -------------------------------------------------------------------------
    // Dividend state
    // -------------------------------------------------------------------------

    /// @dev Accumulated, withdrawable dividend balance per address (in wei).
    mapping(address => uint256) private _withdrawableDividend;

    // =========================================================================
    // IERC20 implementation
    // =========================================================================

    /**
     * @notice Returns the remaining allowance that `spender` is permitted to
     *         spend on behalf of `owner`.
     * @inheritdoc IERC20
     */
    function allowance(address owner, address spender)
        external
        view
        override
        returns (uint256)
    {
        return _allowances[owner][spender];
    }

    /**
     * @notice Approves `spender` to transfer up to `value` tokens on behalf
     *         of the caller.  Overwrites any previously set allowance.
     * @inheritdoc IERC20
     */
    function approve(address spender, uint256 value)
        external
        override
        returns (bool)
    {
        _allowances[msg.sender][spender] = value;
        return true;
    }

    /**
     * @notice Transfers `value` tokens from the caller to `to`.
     * @dev Reverts if the caller has insufficient balance.
     *      A transfer of zero is a valid no-op that does not modify the
     *      holder list.
     * @inheritdoc IERC20
     */
    function transfer(address to, uint256 value)
        external
        override
        returns (bool)
    {
        _transfer(msg.sender, to, value);
        return true;
    }

    /**
     * @notice Transfers `value` tokens from `from` to `to` using the
     *         caller's pre-approved allowance.
     * @dev Reverts if the allowance or the `from` balance is insufficient.
     * @inheritdoc IERC20
     */
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(value <= currentAllowance, "Token: transfer exceeds allowance");

        // Reduce allowance first (CEI)
        _allowances[from][msg.sender] = currentAllowance.sub(value);
        _transfer(from, to, value);
        return true;
    }

    // =========================================================================
    // IMintableToken implementation
    // =========================================================================

    /**
     * @notice Mints tokens equal to the ETH value sent by the caller.
     * @dev    Ratio is always 1 wei : 1 token unit.
     *         Reverts when called with no ETH.
     * @inheritdoc IMintableToken
     */
    function mint() external payable override {
        require(msg.value > 0, "Token: must send ETH to mint");

        // Register as holder before updating balance so the mapping is
        // consistent if _addHolder reads balanceOf (it does not, but for safety).
        _addHolder(msg.sender);
        balanceOf[msg.sender] = balanceOf[msg.sender].add(msg.value);
        totalSupply = totalSupply.add(msg.value);
    }

    /**
     * @notice Burns the caller's entire token balance and sends the equivalent
     *         amount of ETH to `dest`.
     * @dev    Accrued dividends are NOT affected by a burn.
     *         Follows the CEI pattern: state is fully settled before the
     *         external ETH transfer, preventing reentrancy.
     *         Reverts when the caller holds no tokens.
     * @param dest Recipient of the redeemed ETH.
     * @inheritdoc IMintableToken
     */
    function burn(address payable dest) external override {
        uint256 amount = balanceOf[msg.sender];
        require(amount > 0, "Token: nothing to burn");

        // --- Effects (CEI) ---
        balanceOf[msg.sender] = 0;
        totalSupply = totalSupply.sub(amount);
        _removeHolder(msg.sender);

        // --- Interaction (CEI) ---
        dest.transfer(amount);
    }

    // =========================================================================
    // IDividends implementation
    // =========================================================================

    /**
     * @notice Returns the number of addresses that currently hold a non-zero
     *         token balance.
     * @inheritdoc IDividends
     */
    function getNumTokenHolders() external view override returns (uint256) {
        return _holders.length;
    }

    /**
     * @notice Returns the holder address at a given 1-based index, or the
     *         zero address when the index is out of range.
     * @param index 1-based position in the holder list.
     * @inheritdoc IDividends
     */
    function getTokenHolder(uint256 index)
        external
        view
        override
        returns (address)
    {
        if (index == 0 || index > _holders.length) {
            return address(0);
        }
        return _holders[index - 1];
    }

    /**
     * @notice Records a dividend round and assigns each current token holder a
     *         share proportional to their balance relative to the total supply.
     * @dev    The dividend amount equals `msg.value`.
     *         Integer division may leave a small dust remainder inside the
     *         contract; this is an inherent limitation of fixed-point arithmetic
     *         and is consistent with standard dividend-per-share designs.
     *         Reverts when no ETH is provided or when there are no holders.
     * @inheritdoc IDividends
     */
    function recordDividend() external payable override {
        require(msg.value > 0, "Token: dividend must be non-zero");
        require(totalSupply > 0, "Token: no token holders");

        uint256 dividend = msg.value;
        uint256 supply   = totalSupply;
        uint256 len      = _holders.length;

        for (uint256 i = 0; i < len; i++) {
            address holder = _holders[i];
            // Proportional share: holderBalance * dividend / totalSupply
            uint256 share = balanceOf[holder].mul(dividend).div(supply);
            _withdrawableDividend[holder] = _withdrawableDividend[holder].add(share);
        }
    }

    /**
     * @notice Returns the accumulated dividend that `payee` can currently
     *         withdraw (in wei).
     * @inheritdoc IDividends
     */
    function getWithdrawableDividend(address payee)
        external
        view
        override
        returns (uint256)
    {
        return _withdrawableDividend[payee];
    }

    /**
     * @notice Withdraws the caller's entire accumulated dividend, sending it
     *         to `dest` and resetting the internal balance to zero.
     * @dev    Follows the CEI pattern: dividend balance is zeroed before the
     *         external ETH transfer to prevent reentrancy.
     *         Reverts when there is nothing to withdraw.
     * @param dest Recipient of the withdrawn ETH.
     * @inheritdoc IDividends
     */
    function withdrawDividend(address payable dest) external override {
        uint256 amount = _withdrawableDividend[msg.sender];
        require(amount > 0, "Token: no dividend to withdraw");

        // --- Effects (CEI) ---
        _withdrawableDividend[msg.sender] = 0;

        // --- Interaction (CEI) ---
        dest.transfer(amount);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /**
     * @dev Executes a token transfer from `from` to `to`, updating the holder
     *      list when balances cross zero.
     *
     *      A zero-value transfer is a valid, cheap no-op: it passes the
     *      balance check (0 ≤ any uint256) and skips all state mutations,
     *      so the recipient is never added to the holder list with a balance
     *      of zero.
     *
     * @param from  Source address.
     * @param to    Destination address.
     * @param value Number of tokens to move.
     */
    function _transfer(
        address from,
        address to,
        uint256 value
    ) internal {
        require(balanceOf[from] >= value, "Token: insufficient balance");

        if (value > 0) {
            // Update balances
            balanceOf[from] = balanceOf[from].sub(value);
            balanceOf[to]   = balanceOf[to].add(value);

            // Remove sender from holder list if their balance hit zero
            if (balanceOf[from] == 0) {
                _removeHolder(from);
            }

            // Add recipient to holder list if they weren't already there
            _addHolder(to);
        }
    }

    /**
     * @dev Adds `addr` to the holder list if it is not already present.
     *      O(1) – appends to the array and records the 1-based index.
     * @param addr Address to add.
     */
    function _addHolder(address addr) internal {
        if (_holderIndex[addr] == 0) {
            _holders.push(addr);
            _holderIndex[addr] = _holders.length; // 1-based
        }
    }

    /**
     * @dev Removes `addr` from the holder list using a swap-and-pop strategy
     *      so that removal is O(1) and the array stays compact with no gaps.
     *
     *      Steps:
     *        1. Look up `addr`'s 1-based index.
     *        2. If not the last element, overwrite its slot with the last
     *           element and update that element's stored index.
     *        3. Pop the (now-duplicate) last element.
     *        4. Zero out `addr`'s stored index.
     *
     * @param addr Address to remove.
     */
    function _removeHolder(address addr) internal {
        uint256 idx = _holderIndex[addr];
        if (idx == 0) return; // already not a holder

        uint256 lastIdx = _holders.length; // 1-based position of the tail

        if (idx != lastIdx) {
            // Move the tail element into the vacated slot
            address tail = _holders[lastIdx - 1];
            _holders[idx - 1]  = tail;
            _holderIndex[tail] = idx; // update tail's 1-based index
        }

        _holders.pop();
        _holderIndex[addr] = 0;
    }
}