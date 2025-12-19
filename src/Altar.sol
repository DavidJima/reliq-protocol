// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReliqHYPE} from "./ReliqHYPE.sol";

/**
 * @title Altar
 * @author Reliq
 * @notice A sacrificial altar where users contribute backing tokens to collectively purchase ReliqHYPE tokens.
 *         Contributions are capped per user and globally, with optional whitelisting and mint allowances.
 *         After the deadline, the owner can “enter the temple” to swap all backing tokens for ReliqHYPE,
 *         which contributors may then claim pro-rata.
 * @dev    Inherits OpenZeppelin’s Ownable for admin controls and ReentrancyGuard for re-entrancy protection.
 */
contract Altar is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ReliqHYPE public immutable reliq;
    IERC20 public immutable backingToken;

    mapping(address => uint256) public userContributions;
    mapping(address => uint256) public mintAllowance;

    uint256 public maxContribution;
    uint256 public minContribution;
    uint256 public depositCap;

    uint256 public totalContributions;
    uint256 public totalReliqHYPEAcquired;

    uint256 public deadline;

    bool public isWhitelistActive;
    bool public isReliqHYPEClaim;

    /* ------------------------------------------------------
                                EVENTS
       ------------------------------------------------------ */
    event KickOff(uint256 deadline, uint256 minContribution, uint256 maxContribution, uint256 depositCap);
    event Sacrificed(address indexed user, uint256 amount);
    event Unsacrificed(address indexed user, uint256 amount);
    event TempleEntered(uint256 totalBacking, uint256 reliqMinted);
    event OfferingClaimed(address indexed user, uint256 amount);
    event WhitelistToggled(bool active);
    event MintAllowanceSet(address indexed user, uint256 amount);
    event BulkMintAllowanceSet(uint256 count);
    event DeadlineExtended(uint256 newDeadline);
    event ERC20Recovered(address indexed to, address indexed token, uint256 amount);

    constructor(address _reliq, address _backingToken) Ownable(msg.sender) {
        reliq = ReliqHYPE(_reliq);
        backingToken = IERC20(_backingToken);
    }

    /* ------------------------------------------------------
                            CORE LOGIC
       ------------------------------------------------------ */

    function kickOff(uint256 _deadline, uint256 _minContribution, uint256 _maxContribution, uint256 _depositCap)
        external
        onlyOwner
    {
        require(deadline == 0, "Altar: already kicked off");
        require(_deadline > block.timestamp, "Altar: invalid deadline");
        require(_minContribution > 0, "Altar: invalid min contribution");
        require(_maxContribution > _minContribution, "Altar: invalid max contribution");
        require(_depositCap > 0, "Altar: invalid deposit cap");

        deadline = _deadline;
        minContribution = _minContribution;
        maxContribution = _maxContribution;
        depositCap = _depositCap;

        emit KickOff(_deadline, _minContribution, _maxContribution, _depositCap);
    }

    function sacrifice(uint256 amount, address user) external nonReentrant {
        require(block.timestamp < deadline, "Altar: deadline passed");
        require(amount >= minContribution && amount <= maxContribution, "Altar: invalid amount");
        require(totalContributions + amount <= depositCap, "Altar: deposit cap exceeded");

        if (isWhitelistActive) {
            require(mintAllowance[user] >= amount + userContributions[user], "Altar: mint allowance exceeded");
        }

        userContributions[user] += amount;
        totalContributions += amount;

        backingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Sacrificed(user, amount);
    }

    function unsacrifice(uint256 amount) external nonReentrant {
        require(block.timestamp < deadline, "Altar: deadline passed");
        require(amount > 0, "Altar: invalid amount");
        require(
            userContributions[msg.sender] - amount >= minContribution || userContributions[msg.sender] == amount,
            "Altar: invalid amount"
        );

        userContributions[msg.sender] -= amount;
        totalContributions -= amount;

        backingToken.safeTransfer(msg.sender, amount);

        emit Unsacrificed(msg.sender, amount);
    }

    function claimableOffering(address user) public view returns (uint256) {
        if (!isReliqHYPEClaim) return 0;
        if (userContributions[user] == 0) return 0;
        return totalReliqHYPEAcquired * userContributions[user] / totalContributions;
    }

    function receiveOffering() external nonReentrant {
        require(isReliqHYPEClaim, "Altar: ReliqHYPE claim not done");
        uint256 claimable = claimableOffering(msg.sender);
        require(claimable > 0, "Altar: zero claim");

        userContributions[msg.sender] = 0;
        IERC20(reliq).safeTransfer(msg.sender, claimable);

        emit OfferingClaimed(msg.sender, claimable);
    }

    function enterTheTemple() external onlyOwner nonReentrant {
        require(block.timestamp >= deadline, "Altar: deadline not passed");
        require(!isReliqHYPEClaim, "Altar: ReliqHYPE claim already done");
        require(address(reliq) != address(0), "Altar: invalid ReliqHYPE address");

        uint256 totalBacking = backingToken.balanceOf(address(this));
        backingToken.approve(address(reliq), totalBacking);
        reliq.buy(address(this), totalBacking);
        totalReliqHYPEAcquired = reliq.balanceOf(address(this));
        isReliqHYPEClaim = true;

        emit TempleEntered(totalBacking, totalReliqHYPEAcquired);
    }

    /* ------------------------------------------------------
                            ADMIN / CONFIG
       ------------------------------------------------------ */

    function setDeadline(uint256 _deadline) external onlyOwner {
        require(_deadline > deadline, "Altar: invalid deadline");
        deadline = _deadline;
        emit DeadlineExtended(_deadline);
    }

    function toggleWhitelist() external onlyOwner {
        isWhitelistActive = !isWhitelistActive;
        emit WhitelistToggled(isWhitelistActive);
    }

    function setMintAllowance(address _user, uint256 _amount) external onlyOwner {
        require(isWhitelistActive, "Altar: whitelist not active");
        mintAllowance[_user] = _amount;
        emit MintAllowanceSet(_user, _amount);
    }

    function setBulkMintAllowance(address[] calldata _users, uint256[] calldata _amounts) external onlyOwner {
        require(isWhitelistActive, "Altar: whitelist not active");
        require(_users.length <= 300, "Altar: too many users");
        require(_users.length == _amounts.length, "Altar: invalid lengths");

        for (uint256 i; i < _users.length;) {
            mintAllowance[_users[i]] = _amounts[i];
            unchecked {
                ++i;
            }
        }

        emit BulkMintAllowanceSet(_users.length);
    }

    function recoverERC20(address _token) external onlyOwner {
        uint256 amt = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, amt);
        emit ERC20Recovered(msg.sender, _token, amt);
    }
}
