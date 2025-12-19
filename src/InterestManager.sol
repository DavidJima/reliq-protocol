// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IInterestManager} from "./interfaces/IInterestManager.sol";

/**
 * @title InterestManager
 * @author  ...
 * @notice Manages base interest rates for users, allowing per-user overrides of a global default.
 * @dev    Inherits from OpenZeppelin’s Ownable for access control and implements IInterestManager.
 */
contract InterestManager is Ownable, IInterestManager {
    uint256 public defaultBaseRateBPS;
    mapping(address => uint256) public userBaseRateBPS;

    event DefaultBaseRateUpdated(uint256 bps);
    event UserBaseRateUpdated(address indexed user, uint256 bps);
    event BulkUserBaseRatesUpdated(uint256 count);

    constructor(uint256 _defaultBaseRateBPS) Ownable(msg.sender) {
        _setRateBounds(_defaultBaseRateBPS);
        defaultBaseRateBPS = _defaultBaseRateBPS;
        emit DefaultBaseRateUpdated(_defaultBaseRateBPS);
    }

    function setDefaultBaseRate(uint256 bps) external onlyOwner {
        _setRateBounds(bps);
        defaultBaseRateBPS = bps;
        emit DefaultBaseRateUpdated(bps);
    }

    function setUserBaseRate(address user, uint256 bps) external onlyOwner {
        _setRateBounds(bps);
        userBaseRateBPS[user] = bps;
        emit UserBaseRateUpdated(user, bps);
    }

    function unsetUserBaseRate(address user) external onlyOwner {
        delete userBaseRateBPS[user];
        emit UserBaseRateUpdated(user, 0);
    }

    function setBulkUserBaseRates(address[] calldata users, uint256[] calldata bps) external onlyOwner {
        require(users.length == bps.length, "InterestManager: invalid lengths");
        require(users.length <= 300, "InterestManager: too many users");
        for (uint256 i; i < users.length;) {
            _setRateBounds(bps[i]);
            userBaseRateBPS[users[i]] = bps[i];
            unchecked {
                ++i;
            }
        }
        emit BulkUserBaseRatesUpdated(users.length);
    }

    function getInterestRateBPS(address user) external view override returns (uint256) {
        uint256 userRate = userBaseRateBPS[user];
        if (userRate != 0) return userRate;
        return defaultBaseRateBPS;
    }

    function _setRateBounds(uint256 bps) internal pure {
        require(bps <= 10000, "InterestManager: rate too high");
        require(bps >= 10, "InterestManager: rate too low");
    }
}
