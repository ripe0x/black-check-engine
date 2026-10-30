// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import "./interfaces/IChecks.sol";
import "./interfaces/IERC721Receiver.sol";

/**
 * @title  BlackCheck
 * @author VisualizeValue
 * @notice Participation involves engagement with experimental digital artworks on Ethereum.
 *         Mint, extract, and composite are creative acts — not financial transactions or investments.
 *         No offer to sell or buy any security or financial instrument is made or implied.
 *
 *         By interacting, you accept all risks, including potential loss, error, or contract malfunction.
 *         No guarantees exist regarding liquidity, value, availability, or performance.
 *         Checks may be modified or irreversibly transformed by others at any time.
 *         Extraction of some forms, including the Black Check, may be impossible.
 *
 *         All results are part of the artwork.
 *         Value and meaning are subjective.
 *         Participation is voluntary and at your own risk.
 *         You are responsible for following all applicable laws.
 *
 *         This artwork may or may not be notable.
 */
contract BlackCheck is ERC20, IERC721Receiver {
    /// @notice The Checks Originals contract
    IChecks public constant CHECKS = IChecks(0x036721e5A769Cc48B3189EFbb9ccE4471E8A48B1);

    /// @notice 1 / ∞ (This is one artifact)
    uint256 public constant MAX_SUPPLY = 1 * 10**18;

    /// @notice Emitted when $BLKCHK tokens are minted
    event Mint(address indexed to, uint256 indexed checkId, uint256 amount);

    /// @notice Emitted when a Check is exchanged for $BLKCHK
    event Exchange(address indexed from, uint256 indexed checkId, uint256 amount);

    /// @notice Emitted when Checks are composited
    event Composite(uint256 indexed keepId, uint256 indexed burnId, address compositor);

    /// @notice Emitted when the Black Check is created
    event One(uint256 indexed blackCheckId, address creator);

    error InvalidOrder();
    error MaxSupplyExceeded();
    error OnlyChecksContract();
    error NoEthAccepted();
    error NotAllowed();

    /// @notice Returns the name of the token
    function name() public pure override returns (string memory) {
        return "Black Check";
    }

    /// @notice Returns the symbol of the token
    function symbol() public pure override returns (string memory) {
        return "$BLKCHK";
    }

    /// @notice Deposit Checks Originals to receive $BLKCHK tokens. Note the checks held
    ///         by this contract can be composited by anybody at any time so you
    ///         might not be able to retrieve your check.
    /// @dev This function is called by the Checks contract when a Check is transferred to this contract
    function onERC721Received(
        address /* operator */,
        address from,
        uint256 tokenId,
        bytes calldata /* data */
    ) external override returns (bytes4) {
        // Only accept Checks NFTs
        if (msg.sender != address(CHECKS)) revert OnlyChecksContract();

        _processMint(from, tokenId);

        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Mint $BLKCHK by transferring in Checks Originals
    /// @param checkIds Array of Check IDs to mint tokens for (must be approved to this contract)
    /// @dev Anyone can call this function. Tokens are always minted to the NFT owner, not the caller.
    function mint(uint256[] calldata checkIds) external {
        for (uint256 i = 0; i < checkIds.length; i++) {
            // Get the owner of the check
            address owner = CHECKS.ownerOf(checkIds[i]);

            // Check whether this contract is allowed to transfer this Check
            // Requires owner to have approved this contract via approve() or setApprovalForAll()
            if (
                CHECKS.getApproved(checkIds[i]) != address(this) &&
                (!CHECKS.isApprovedForAll(owner, address(this)))
            ) { revert NotAllowed(); }

            // Transfer the Check NFT from the owner to this contract
            CHECKS.transferFrom(owner, address(this), checkIds[i]);

            // Mint tokens to the owner (not the caller)
            _processMint(owner, checkIds[i]);
        }
    }

    /// @notice Exchange $BLKCHK tokens for a specific Check NFT
    /// @param checkId The ID of the Check to exchange for
    function exchange(uint256 checkId) external {
        // Compute the $BLKCHK allocation for this Checks Original
        uint256 burnAmount = _calculateAmount(CHECKS.getCheck(checkId).stored.divisorIndex);

        // Burn tokens (reverts on insufficient balance)
        _burn(msg.sender, burnAmount);

        // Transfer the Check NFT to the caller (will revert if we don't own it)
        CHECKS.safeTransferFrom(address(this), msg.sender, checkId);

        emit Exchange(msg.sender, checkId, burnAmount);
    }

    /// @notice Composite two Checks held by this contract
    /// @param keepId The token ID to keep
    /// @param burnId The token ID to burn
    /// @dev Anyone can call this to composite towards the Black Check
    function composite(uint256 keepId, uint256 burnId) external {
        // Enforce that keepId is always smaller than burnId
        if (keepId > burnId) revert InvalidOrder();

        // Perform the composite (Checks contract validates ownership and compatibility)
        CHECKS.composite(keepId, burnId, false);

        emit Composite(keepId, burnId, msg.sender);
    }

    /// @notice Create a Black Check from 64 single-check tokens
    /// @param tokenIds Array of 64 single-check token IDs, with the smallest ID at index 0
    /// @dev Anyone can call this. The first check in the list will survive as the Black Check
    function one(uint256[] calldata tokenIds) external {
        uint256 id = tokenIds[0];

        // Verify that the id is the smallest
        for (uint256 i = 1; i < 64; i++) {
            if (tokenIds[i] < id) revert InvalidOrder();
        }

        // Call infinity on the Checks contract (validates single checks and ownership)
        CHECKS.infinity(tokenIds);

        emit One(id, msg.sender);
    }

    /// @dev Process a deposit and mint tokens
    /// @param to The address to mint tokens to
    /// @param checkId The ID of the Check being deposited
    function _processMint(address to, uint256 checkId) private {
        // Mint amount is based on the checks count
        uint256 mintAmount = _calculateAmount(CHECKS.getCheck(checkId).stored.divisorIndex);

        // Check max supply
        if (totalSupply() + mintAmount > MAX_SUPPLY) revert MaxSupplyExceeded();

        // Mint tokens to the recipient
        _mint(to, mintAmount);

        emit Mint(to, checkId, mintAmount);
    }

    /// @dev Calculate the amount of tokens to mint for a given check
    /// @param divisorIndex The divisor index of the check (0-7)
    /// @return The amount of tokens (with 18 decimals)
    function _calculateAmount(uint8 divisorIndex) private pure returns (uint256) {
        // Black check (divisorIndex 7) represents the entire minted token supply
        if (divisorIndex == 7) return MAX_SUPPLY;

        // For divisorIndex 0-6, use the exponential formula
        return ((1 << divisorIndex) * 10**18) / 4096;
    }

    /// @notice Reject all ETH transfers
    receive() external payable {
        revert NoEthAccepted();
    }

    /// @notice Reject all ETH transfers
    fallback() external payable {
        revert NoEthAccepted();
    }
}
