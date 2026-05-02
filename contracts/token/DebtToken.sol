// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

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

    /// @dev borrower => tokenId[] (tra cứu nhanh)
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
        if (!authorizedMinters[msg.sender] && msg.sender != owner()) {
            revert NotAuthorizedMinter();
        }
        _;
    }

    // ===== CONSTRUCTOR =====

    constructor(address initialOwner) ERC721("P2P Lending Debt Token", "DEBT") Ownable(initialOwner) {
        authorizedMinters[initialOwner] = true;
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

        borrowerDebts[borrower].push(tokenId);

        emit DebtTokenMinted(tokenId, borrower, loanId, debtAmount, reason);
    }

    // ===== VIEW FUNCTIONS =====

    /**
     * @dev Lấy tổng số DebtToken của borrower
     * Lender nên kiểm tra trước khi fund
     */
    function getDebtCount(address borrower) external view returns (uint256) {
        return borrowerDebts[borrower].length;
    }

    /**
     * @dev Lấy danh sách DebtToken IDs của borrower
     */
    function getBorrowerDebtTokens(address borrower) external view returns (uint256[] memory) {
        return borrowerDebts[borrower];
    }

    /**
     * @dev Lấy chi tiết DebtRecord
     */
    function getDebtRecord(uint256 tokenId) external view returns (DebtRecord memory) {
        return debtRecords[tokenId];
    }

    /**
     * @dev Tổng nợ xấu tích lũy của borrower
     */
    function getTotalDebt(address borrower) external view returns (uint256 total) {
        uint256[] memory debts = borrowerDebts[borrower];
        for (uint256 i = 0; i < debts.length; i++) {
            total += debtRecords[debts[i]].debtAmount;
        }
    }

    /**
     * @dev Kiểm tra borrower có nợ xấu không
     */
    function hasDebt(address borrower) external view returns (bool) {
        return borrowerDebts[borrower].length > 0;
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
