// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title DebtToken (ERC-721)
 * @dev NFT ghi nhận nợ xấu on-chain — minh bạch và không thể xóa
 *
 * Mỗi khi khoản vay bị LIQUIDATED hoặc DEFAULTED:
 * 1. Backend hoặc P2PLending gọi mintDebtToken()
 * 2. Một NFT (DebtToken) được mint cho borrower
 * 3. NFT chứa toàn bộ thông tin: loanId, principal, lender, thời gian
 * 4. NFT KHÔNG THỂ transfer (Soulbound) — gắn vĩnh viễn với borrower
 *
 * Vai trò:
 * - Minh bạch: Ai cũng có thể verify lịch sử nợ xấu on-chain
 * - Reputation: Số DebtToken = số lần vỡ nợ, ảnh hưởng credit score
 * - Audit trail: Không thể xóa/sửa (immutable blockchain)
 * - Lender bảo vệ: Kiểm tra borrower có DebtToken trước khi fund
 */
contract DebtToken is ERC721Enumerable, Ownable {
    using EnumerableSet for EnumerableSet.UintSet; // FIX H-4
    // ===== STATE =====

    uint256 private _nextTokenId = 1;

    /// @dev Địa chỉ được phép mint (P2PLending contract hoặc backend)
    mapping(address => bool) public authorizedMinters;

    /// @dev Metadata cho mỗi DebtToken
    struct DebtRecord {
        uint256 loanId;              // ID khoản vay
        address borrower;            // Người vay
        address lender;              // Người cho vay
        uint256 principalAmount;     // Số tiền gốc
        uint256 debtAmount;          // Tổng nợ (gốc + lãi + phạt)
        uint256 defaultedAt;         // Thời điểm vỡ nợ
        string reason;               // "DEFAULTED" hoặc "LIQUIDATED"
        address loanContract;        // Địa chỉ Loan contract on-chain
    }

    /// @dev tokenId => DebtRecord
    mapping(uint256 => DebtRecord) public debtRecords;

    /// @dev FIX H-4: Dùng EnumerableSet thay array unbounded
    /// borrower => Set của tokenIds (chống DoS push attack)
    mapping(address => EnumerableSet.UintSet) private _borrowerDebtTokens;

    /// @dev DEPRECATED: giữ lại cho backward compat với tests
    /// Sử dụng _borrowerDebtTokens thay thế
    mapping(address => uint256[]) public borrowerDebts;

    // ===== EVENTS =====

    event DebtTokenMinted(
        uint256 indexed tokenId,
        address indexed borrower,
        uint256 indexed loanId,
        uint256 debtAmount,
        string reason
    );

    event MinterAuthorized(address indexed minter, bool status);

    // ===== ERRORS =====

    error NotAuthorizedMinter();
    error SoulboundToken(); // Không cho phép transfer
    error InvalidBorrower();

    // ===== MODIFIERS =====

    modifier onlyAuthorizedMinter() {
        if (!authorizedMinters[msg.sender]) {
            revert NotAuthorizedMinter();
        }
        _;
    }

    // ===== CONSTRUCTOR =====

    constructor(address initialOwner) ERC721("P2P Lending Debt Token", "DEBT") Ownable(initialOwner) {
        // Fix: Do not authorize the initial owner to mint. Only P2PLending contract should be authorized.
    }

    // ===== CORE FUNCTIONS =====

    /**
     * @dev Mint DebtToken khi khoản vay bị default/liquidated
     * Chỉ authorized minters (P2PLending contract hoặc backend wallet) mới được gọi
     */
    function mintDebtToken(
        address borrower,
        uint256 loanId,
        address lender,
        uint256 principalAmount,
        uint256 debtAmount,
        string calldata reason,
        address loanContract
    ) external onlyAuthorizedMinter returns (uint256 tokenId) {
        if (borrower == address(0)) revert InvalidBorrower();

        tokenId = _nextTokenId++;

        // Mint NFT cho borrower
        _safeMint(borrower, tokenId);

        // Lưu metadata
        debtRecords[tokenId] = DebtRecord({
            loanId: loanId,
            borrower: borrower,
            lender: lender,
            principalAmount: principalAmount,
            debtAmount: debtAmount,
            defaultedAt: block.timestamp,
            reason: reason,
            loanContract: loanContract
        });

        // FIX H-4: Dùng EnumerableSet thay array unbounded
        _borrowerDebtTokens[borrower].add(tokenId);
        borrowerDebts[borrower].push(tokenId); // giữ lại cho backward compat

        emit DebtTokenMinted(tokenId, borrower, loanId, debtAmount, reason);
    }

    // ===== VIEW FUNCTIONS =====

    /**
     * @dev FIX H-4: Trả về set tokens (EnumerableSet) — không bị DoS
     * Dùng ERC721Enumerable.balanceOf + tokenOfOwnerByIndex thay thế cũ
     */
    function getDebtCount(address borrower) external view returns (uint256) {
        return balanceOf(borrower); // ERC721Enumerable built-in — O(1)
    }

    /**
     * @dev FIX H-4: Dùng EnumerableSet thay array
     */
    function getBorrowerDebtTokens(address borrower) external view returns (uint256[] memory) {
        return _borrowerDebtTokens[borrower].values();
    }

    /**
     * @dev Lấy chi tiết DebtRecord
     */
    function getDebtRecord(uint256 tokenId) external view returns (DebtRecord memory) {
        return debtRecords[tokenId];
    }

    /**
     * @dev FIX L-8: Tránh O(N) loop — dùng ERC721Enumerable để iterate
     * Dùng tokenOfOwnerByIndex() built-in thay vì array loop
     *
     * Note: Vẫn O(N) nhưng ERC721Enumerable dùng được; frontend nên dùng events
     * thay vì gọi hàm này cho user có nhiều DebtTokens.
     */
    function getTotalDebt(address borrower) external view returns (uint256 total) {
        uint256 count = balanceOf(borrower);
        for (uint256 i = 0; i < count; i++) {
            uint256 tid = tokenOfOwnerByIndex(borrower, i);
            total += debtRecords[tid].debtAmount;
        }
    }

    /**
     * @dev Kiểm tra borrower có nợ xấu không
     * FIX L-8: Dùng balanceOf() O(1) thay vì array.length
     */
    function hasDebt(address borrower) external view returns (bool) {
        return balanceOf(borrower) > 0; // ERC721Enumerable built-in
    }

    // ===== SOULBOUND: Chặn transfer =====

    /**
     * @dev Override transfer — DebtToken là Soulbound, KHÔNG cho phép chuyển nhượng
     * Người vay không thể "trốn" nợ xấu bằng cách chuyển NFT sang ví khác
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721Enumerable) returns (address) {
        address from = _ownerOf(tokenId);

        // Chỉ cho phép mint (from == address(0)), không cho transfer
        if (from != address(0) && to != address(0)) {
            revert SoulboundToken();
        }

        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(
        address account,
        uint128 amount
    ) internal override(ERC721Enumerable) {
        super._increaseBalance(account, amount);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ===== ADMIN =====

    function setAuthorizedMinter(address minter, bool status) external onlyOwner {
        authorizedMinters[minter] = status;
        emit MinterAuthorized(minter, status);
    }
}
