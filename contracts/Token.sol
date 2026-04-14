pragma solidity 0.7.0;

import "./IERC20.sol";
import "./IMintableToken.sol";
import "./IDividends.sol";
import "./SafeMath.sol";

contract Token is IERC20, IMintableToken, IDividends {
  // ------------------------------------------ //
  // ----- BEGIN: DO NOT EDIT THIS SECTION ---- //
  // ------------------------------------------ //
  using SafeMath for uint256;
  uint256 public totalSupply;
  uint256 public decimals = 18;
  string public name = "Test token";
  string public symbol = "TEST";
  mapping (address => uint256) public balanceOf;
  // ------------------------------------------ //
  // ----- END: DO NOT EDIT THIS SECTION ------ //  
  // ------------------------------------------ //

  address[] private _holders;
  mapping(address => uint256) private _holderIndex;
  mapping(address => mapping(address => uint256)) private _allowances;

  // Dividend accounting
  uint256 private constant PRECISION = 1e18;
  uint256 private _accDividendPerShare;
  mapping(address => uint256) private _dividendDebt;
  mapping(address => uint256) private _dividends;

  // Reentrancy guard
  uint256 private _locked = 1;

  // Events

  event Transfer(address indexed from, address indexed to, uint256 value);
  event Approval(address indexed owner, address indexed spender, uint256 value);
  event Mint(address indexed account, uint256 amount);
  event Burn(address indexed account, address indexed destination, uint256 amount);
  event DividendRecorded(address indexed sender, uint256 amount, uint256 accDividendPerShare);
  event DividendWithdrawn(address indexed account, address indexed destination, uint256 amount);

  // Helpers

  modifier nonReentrant() {
    require(_locked == 1, "ReentrancyGuard: reentrant call");
    _locked = 2;
    _;
    _locked = 1;
  }

  function _addHolder(address holder) private {
    if (_holderIndex[holder] == 0) {
      _holders.push(holder);
      _holderIndex[holder] = _holders.length; // 1-based
    }
  }

  function _removeHolder(address holder) private {
    uint256 idx = _holderIndex[holder];
    if (idx != 0) {
      uint256 lastIndex = _holders.length - 1;
      address last = _holders[lastIndex];

      _holders[idx - 1] = last;
      _holderIndex[last] = idx;

      _holders.pop();
      _holderIndex[holder] = 0;
    }
  }

  function _updateHolderStatus(address holder) private {
    if (balanceOf[holder] > 0) {
      _addHolder(holder);
    } else {
      _removeHolder(holder);
    }
  }

  function _accumulatedDividend(address account) private view returns (uint256) {
    return balanceOf[account].mul(_accDividendPerShare).div(PRECISION);
  }

  function _settleAccount(address account) private {
    uint256 accumulated = _accumulatedDividend(account);
    uint256 debt = _dividendDebt[account];

    if (accumulated > debt) {
      _dividends[account] = _dividends[account].add(accumulated.sub(debt));
    }

    _dividendDebt[account] = accumulated;
  }

  function _afterBalanceChange(address account) private {
    _dividendDebt[account] = _accumulatedDividend(account);
    _updateHolderStatus(account);
  }

  // IERC20

  function allowance(address owner, address spender) external view override returns (uint256) {
    return _allowances[owner][spender];
  }

  function transfer(address to, uint256 value) external override returns (bool) {
    require(to != address(0), "Invalid recipient");
    require(balanceOf[msg.sender] >= value, "Insufficient balance");

    if (value == 0) {
      emit Transfer(msg.sender, to, 0);
      return true;
    }

    _settleAccount(msg.sender);
    _settleAccount(to);

    balanceOf[msg.sender] = balanceOf[msg.sender].sub(value);
    balanceOf[to] = balanceOf[to].add(value);

    _afterBalanceChange(msg.sender);
    _afterBalanceChange(to);

    emit Transfer(msg.sender, to, value);
    return true;
  }

  function approve(address spender, uint256 value) external override returns (bool) {
    require(spender != address(0), "Invalid spender");
    _allowances[msg.sender][spender] = value;
    emit Approval(msg.sender, spender, value);
    return true;
  }

  function transferFrom(address from, address to, uint256 value) external override returns (bool) {
    require(from != address(0), "Invalid sender");
    require(to != address(0), "Invalid recipient");
    require(balanceOf[from] >= value, "Insufficient balance");
    require(_allowances[from][msg.sender] >= value, "Insufficient allowance");

    if (value == 0) {
      emit Transfer(from, to, 0);
      return true;
    }

    _settleAccount(from);
    _settleAccount(to);

    _allowances[from][msg.sender] = _allowances[from][msg.sender].sub(value);
    balanceOf[from] = balanceOf[from].sub(value);
    balanceOf[to] = balanceOf[to].add(value);

    _afterBalanceChange(from);
    _afterBalanceChange(to);

    emit Approval(from, msg.sender, _allowances[from][msg.sender]);
    emit Transfer(from, to, value);
    return true;
  }

  // IMintableToken

  function mint() external payable override {
    require(msg.value > 0, "Must send ETH");

    _settleAccount(msg.sender);

    balanceOf[msg.sender] = balanceOf[msg.sender].add(msg.value);
    totalSupply = totalSupply.add(msg.value);

    _afterBalanceChange(msg.sender);

    emit Mint(msg.sender, msg.value);
    emit Transfer(address(0), msg.sender, msg.value);
  }

  function burn(address payable dest) external override nonReentrant {
    require(dest != address(0), "Invalid destination");

    uint256 amount = balanceOf[msg.sender];
    require(amount > 0, "Nothing to burn");

    _settleAccount(msg.sender);

    balanceOf[msg.sender] = 0;
    totalSupply = totalSupply.sub(amount);

    _dividendDebt[msg.sender] = 0;
    _updateHolderStatus(msg.sender);

    (bool ok, ) = dest.call{value: amount}("");
    require(ok, "ETH transfer failed");

    emit Burn(msg.sender, dest, amount);
    emit Transfer(msg.sender, address(0), amount);
  }

  // IDividends

  function getNumTokenHolders() external view override returns (uint256) {
    return _holders.length;
  }

  function getTokenHolder(uint256 index) external view override returns (address) {
    if (index == 0 || index > _holders.length) {
      return address(0);
    }
    return _holders[index - 1];
  }

  function recordDividend() external payable override {
    require(msg.value > 0, "Must send ETH");
    require(totalSupply > 0, "No supply");

    _accDividendPerShare = _accDividendPerShare.add(
      msg.value.mul(PRECISION).div(totalSupply)
    );

    emit DividendRecorded(msg.sender, msg.value, _accDividendPerShare);
  }

  function getWithdrawableDividend(address payee) external view override returns (uint256) {
    uint256 accumulated = _accumulatedDividend(payee);
    uint256 debt = _dividendDebt[payee];
    uint256 pending = _dividends[payee];

    if (accumulated > debt) {
      return pending.add(accumulated.sub(debt));
    }

    return pending;
  }

  function withdrawDividend(address payable dest) external override nonReentrant {
    require(dest != address(0), "Invalid destination");

    _settleAccount(msg.sender);

    uint256 amount = _dividends[msg.sender];
    require(amount > 0, "No dividend");

    _dividends[msg.sender] = 0;

    (bool ok, ) = dest.call{value: amount}("");
    require(ok, "ETH transfer failed");

    emit DividendWithdrawn(msg.sender, dest, amount);
  }

  // Extra

  function getAccDividendPerShare() external view returns (uint256) {
    return _accDividendPerShare;
  }

  function getDividendDebt(address account) external view returns (uint256) {
    return _dividendDebt[account];
  }

  function getStoredDividend(address account) external view returns (uint256) {
    return _dividends[account];
  }

  function getPendingDividend(address account) external view returns (uint256) {
    uint256 accumulated = _accumulatedDividend(account);
    uint256 debt = _dividendDebt[account];

    if (accumulated > debt) {
      return accumulated.sub(debt);
    }

    return 0;
  }
}