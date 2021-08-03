// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/SafeERC20.sol";
import "./libs/IMasterChef.sol";

// Miner governs the transaction mining of ROLL rewards and distribution of referral fees.
/*
Miner contract is responsible for the following tasks:
- Collect ROLL yield from MasterChef using a dummy ERC20 token.
- Record game rewards of players.
- Record referrer address of players.
- Distribute game rewards to players.
- Distribute referral fee to referrers.
*/
contract Miner is Ownable, ReentrancyGuard {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    // ROLL token contract.
    IERC20 constant ROLL_TOKEN = IERC20(0xC68e83a305b0FaD69E264A1769a0A070F190D2d6);

    // MasterChef contract is the yield farm for ROLL token.
    IMasterChef constant masterChef = IMasterChef(0x3C58EA8D37f4fc6882F678f822E383Df39260937);

    // PolyrollRoll contract address. Distribute some ROLL emissions to ROLL game contract.
    address public polyrollRoll;

    // Percentage of ROLL harvested to go to ROLL game contract.
    uint public polyrollRollPct = 10;

    // Pool ID on MasterChef used for staking
    uint public pid;

    // Referral fee rate in basis points.
    uint public referralFeeBP = 1000;
    
    // Total pending ROLL rewards by all users.
    uint public allPendingReward;

    // Map user address to pending ROLL rewards.
    mapping(address => uint) public userReward;

    // Map user address to referrer address.
    mapping(address => address) public userReferrer;

    // Map referrer address to number of referees.
    mapping(address => uint) public referralsCount;

    // Map game contract addresses to boolean.
    // Used to decide if a contract is approved to call functions with onlyGame modifier.
    mapping(address => bool) public isGame;

    // Event logs
    event Withdraw(address indexed user, uint amount);
    event ReferralRecorded(address indexed user, address indexed referrer);
    event ReferralFeePaid(address indexed user, address indexed referrer, uint referralFee);

    // Constructor.
    constructor() public {}
    
    modifier onlyGame {
        require(isGame[msg.sender], "Only approved game contracts can call function");
        _;
    }

    // Allow MasterChef contract to accept staking tokens from Miner contract.
    function approveSpender(IERC20 _tokenAddress) external onlyOwner {
        IERC20(_tokenAddress).safeApprove(address(masterChef), 115792089237316195423570985008687907853269984665640564039457584007913129639935);
    }

    // Stake dummy token in MasterChef pool to earn ROLL.
    function depositMasterChef(uint _amount) external onlyOwner {
        masterChef.deposit(pid, _amount, 0x0000000000000000000000000000000000000000);
    }

    // Unstake dummy token from MasterChef pool.
    function withdrawMasterChef(uint _amount) external onlyOwner {
        masterChef.withdraw(pid, _amount);
    }

    // Harvest ROLL token from MasterChef pool.
    function harvestMasterChef() internal {

        // Store initial balance.
        uint initialBalance = ROLL_TOKEN.balanceOf(address(this));

        // Harvest ROLL from masterChef.
        masterChef.withdraw(pid, 0);

        // Compute amount of ROLL harvested.
        uint harvestAmount = ROLL_TOKEN.balanceOf(address(this)) - initialBalance;

        // Allocate some ROLL to ROLL game contract.
        safeRollTransfer(polyrollRoll, harvestAmount.mul(polyrollRollPct).div(100));
    }

    // Set pool ID.
    function setPid(uint _pid) external onlyOwner {
        pid = _pid;
    }

    // Set game contracts that are allowed to call addReward.
    function setGame(address _GameAddress, bool _isAllowed) external onlyOwner {
        isGame[_GameAddress] = _isAllowed;
    }

    // Set PolyrollRoll contract address.
    function setPolyrollRoll(address _polyrollRoll) external onlyOwner {
        polyrollRoll = _polyrollRoll;
    }

    // Set percentage of ROLL harvested to go to ROLL game contract.
    function setPolyrollRollPct(uint _polyrollRollPct) external onlyOwner {
        polyrollRollPct = _polyrollRollPct;
    }

    // Set referral fee basis points.
    function setReferralFeeBP(uint16 _referralFeeBP) external onlyOwner {
        require(referralFeeBP <= 10000, "Referral fee basis point exceeds limit");
        referralFeeBP = _referralFeeBP;
    }

    // Record referrer address only during user's first bet.
    function recordReferrer(address _user, address _referrer) external onlyGame {
        // Ensure this is user's first bet.
        if (userReferrer[_user] == address(0) && _referrer != _user) {
            if (_referrer == address(0)) {
                // If referrer is blank, set referrer to burn address as placeholder to acknowledge first bet is placed.
                // Referral fee will not be actually sent to burn address.
                userReferrer[_user] = 0x000000000000000000000000000000000000dEaD;
            } else {
                // If referrer is not blank, set referrer.
                userReferrer[_user] = _referrer;
                referralsCount[_referrer] += 1;
                emit ReferralRecorded(_user, _referrer);
            }
        }
    }

    // Allow Polyroll game contract to add pending ROLL rewards for user.
    function addReward(address _user, uint _amount) external onlyGame {
        // Ensure reward amount is a sane number
        if (_amount > 400000 ether) {
            _amount = 400000 ether;
        }

        // Update user's pending reward
        userReward[_user] = userReward[_user].add(_amount);
        allPendingReward = allPendingReward.add(_amount);
    }

    // Withdraw pending ROLL rewards.
    function withdraw() public nonReentrant {
        uint pending = userReward[msg.sender];
        harvestMasterChef();
        require(pending <= ROLL_TOKEN.balanceOf(address(this)), "Withdrawal exceeds balance. Wait for Miner to farm more ROLL.");
        if (pending > 0) {
            allPendingReward = allPendingReward.sub(pending);
            userReward[msg.sender] = 0;
            safeRollTransfer(msg.sender, pending);
            payReferralFee(msg.sender, pending);
            emit Withdraw(msg.sender, pending);
        }
    }

    // Safe ROLL transfer function, in case if rounding error causes pool to not have enough ROLL.
    function safeRollTransfer(address _to, uint _pending) internal {
        uint rollBal = ROLL_TOKEN.balanceOf(address(this));
        if (_pending > rollBal) {
            ROLL_TOKEN.transfer(_to, rollBal);
        } else {
            ROLL_TOKEN.transfer(_to, _pending);
        }
    }

    // Pay referral fee to the referrer, if any.
    function payReferralFee(address _user, uint _pending) internal {
        if (referralFeeBP > 0) {
            address referrer = userReferrer[_user];
            if (referrer != address(0) && referrer != 0x000000000000000000000000000000000000dEaD) {
                uint referralFee = _pending.mul(referralFeeBP).div(10000);
                safeRollTransfer(referrer, referralFee);
                emit ReferralFeePaid(msg.sender, referrer, referralFee);
            }
        }
    }
}