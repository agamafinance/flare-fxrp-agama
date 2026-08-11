// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface ISplitterHook {
    function ytSettle(address user) external; // accrue pending at current balance
    function ytResetDebt(address user) external; // reset yield debt to new balance
}

/**
 * @title SplitToken
 * @notice Minimal ERC20 minted/burned only by the YieldSplitter. Used for both
 *         PT (principal) and YT (yield). The YT instance is "yieldBearing": every
 *         transfer settles pending yield for both parties (MasterChef-style) so yield
 *         accounting stays correct even when YT changes hands.
 */
contract SplitToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals; // match the underlying (FXRP = 6)
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public immutable splitter;
    bool public immutable yieldBearing;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory n, string memory s, uint8 _decimals, address _splitter, bool _yieldBearing) {
        name = n;
        symbol = s;
        decimals = _decimals;
        splitter = _splitter;
        yieldBearing = _yieldBearing;
    }

    modifier onlySplitter() {
        require(msg.sender == splitter, "only splitter");
        _;
    }

    function mint(address to, uint256 a) external onlySplitter {
        totalSupply += a;
        balanceOf[to] += a;
        emit Transfer(address(0), to, a);
    }

    function burn(address from, uint256 a) external onlySplitter {
        balanceOf[from] -= a;
        totalSupply -= a;
        emit Transfer(from, address(0), a);
    }

    function approve(address sp, uint256 a) external returns (bool) {
        allowance[msg.sender][sp] = a;
        emit Approval(msg.sender, sp, a);
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _t(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        require(al >= a, "allowance");
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        _t(f, to, a);
        return true;
    }

    function _t(address f, address to, uint256 a) internal {
        if (yieldBearing) {
            // settle both at OLD balances, then move, then reset debts at NEW balances
            ISplitterHook(splitter).ytSettle(f);
            ISplitterHook(splitter).ytSettle(to);
        }
        require(balanceOf[f] >= a, "balance");
        balanceOf[f] -= a;
        balanceOf[to] += a;
        if (yieldBearing) {
            ISplitterHook(splitter).ytResetDebt(f);
            ISplitterHook(splitter).ytResetDebt(to);
        }
        emit Transfer(f, to, a);
    }
}
