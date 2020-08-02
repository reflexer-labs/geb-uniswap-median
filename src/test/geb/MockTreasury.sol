/// MockTreasury.sol

// Copyright (C) 2020 Reflexer Labs, INC

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.6.7;

abstract contract SystemCoinLike {
    function balanceOf(address) virtual public view returns (uint);
    function approve(address, uint) virtual public returns (uint);
    function transfer(address,uint) virtual public returns (bool);
    function transferFrom(address,address,uint) virtual public returns (bool);
}

contract MockTreasury {
    SystemCoinLike  public systemCoin;

    modifier accountNotTreasury(address account) {
        require(account != address(this), "MockTreasury/account-cannot-be-treasury");
        _;
    }

    constructor(
        address systemCoin_
    ) public {
        systemCoin  = SystemCoinLike(systemCoin_);
    }

    // --- Math ---
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    function pullFunds(address dstAccount, address token, uint wad) external accountNotTreasury(dstAccount) {
        require(dstAccount != address(0), "MockTreasury/null-dst");
        require(wad > 0, "MockTreasury/null-transfer-amount");
        require(token == address(systemCoin), "MockTreasury/token-unavailable");
        require(systemCoin.balanceOf(address(this)) >= wad, "MockTreasury/not-enough-funds");
        // Transfer money
        systemCoin.transfer(dstAccount, wad);
    }
}

contract MockRevertableTreasury {
    SystemCoinLike  public systemCoin;

    constructor() public {
        systemCoin = SystemCoinLike(address(0x123));
    }

    function pullFunds(address dstAccount, address token, uint wad) external {
        revert();
    }
}
