// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "https://github.com/smartcontractkit/chainlink/blob/0964ca290565587963cc4ad8f770274f5e0d9e9d/evm-contracts/src/v0.6/VRFConsumerBase.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/SafeERC20.sol";
import "./libs/IMiner.sol";

// PolyrollRoll is the dealer of ROLL token based random number games at Polyroll.org: Coin Flip, Dice Roll, Polyroll, Roulette.
/*
v2 has the same logic as v1, with the following updates:
- Transaction Mining: Contract is linked to TransactionMiner contract to award ROLL tokens to gamblers who lost their bets.
- Referral system: Contract is linked to TransactionMiner contract to record a gambler's referrer and distribute referral fees.
- Automated risk management: Dynamically computes maxProfit based on contract balance and balance-to-maxProfit ratio.
- Reward Computation: Calculates txn mining reward based on rewardPct, bet amount, and probability of loss.
- House edge and wealth tax are in basis points instead of percentage for fine adjustments.
- betPlaced event log is more detailed to allow users to see their pending bets while waiting for them to be settled.
- betSettled event log is less detailed to save gas fee paid by Chainlink VRF. Allows settleBet txn to be confirmed faster by Polygon nodes.
*/
contract PolyrollRoll is VRFConsumerBase, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Import contract that governs transaction mining and referral fees
    IMiner public miner;

    // Token to be used in this game contract
    address public constant GAME_TOKEN = 0xC68e83a305b0FaD69E264A1769a0A070F190D2d6;

    // Chainlink VRF related parameters
    address public constant LINK_TOKEN = 0xb0897686c545045aFc77CF20eC7A532E3120E0F1;
    address public constant VRF_COORDINATOR = 0x3d2341ADb2D31f1c5530cDC622016af293177AE0;
    bytes32 public keyHash = 0xf86195cf7690c55907b2b611ebb7343a6f649bff128701cc542f0569e2c549da;
    uint public chainlinkFee = 100000000000000; // 0.0001 LINK
    uint maxReward = 20000 ether;

    // Each bet is deducted 100 basis points (1%) in favor of the house
    uint public houseEdgeBP = 100;

    // Modulo is the number of equiprobable outcomes in a game:
    //  2 for coin flip
    //  6 for dice roll
    //  36 for double dice roll
    //  37 for roulette
    //  100 for polyroll
    uint constant MAX_MODULO = 100;

    // Modulos below MAX_MASK_MODULO are checked against a bit mask, allowing betting on specific outcomes. 
    // For example in a dice roll (modolo = 6), 
    // 000001 mask means betting on 1. 000001 converted from binary to decimal becomes 1.
    // 101000 mask means betting on 4 and 6. 101000 converted from binary to decimal becomes 40.
    // The specific value is dictated by the fact that 256-bit intermediate
    // multiplication result allows implementing population count efficiently
    // for numbers that are up to 42 bits, and 40 is the highest multiple of eight below 42.
    uint constant MAX_MASK_MODULO = 40;

     // This is a check on bet mask overflow. Maximum mask is equivalent to number of possible binary outcomes for maximum modulo.
    uint constant MAX_BET_MASK = 2 ** MAX_MASK_MODULO;

    // These are constants that make O(1) population count in placeBet possible.
    uint constant POPCNT_MULT = 0x0000000000002000000000100000000008000000000400000000020000000001;
    uint constant POPCNT_MASK = 0x0001041041041041041041041041041041041041041041041041041041041041;
    uint constant POPCNT_MODULO = 0x3F;

    // In addition to house edge, wealth tax is added for bet amount that exceeds a multiple of wealthTaxThreshold.
    // For example, if wealthTaxThreshold = 200 ether and wealthTaxBP = 100,
    // A bet amount of 200 ether will have a wealth tax of 1% in addition to house edge.
    // A bet amount of 400 ether will have a wealth tax of 2% in addition to house edge.
    uint public wealthTaxThreshold = 2000 ether;
    uint public wealthTaxBP = 0;

    // Minimum and maximum bet amounts.
    uint public minBetAmount = 2 ether;
    uint public maxBetAmount = 10000 ether;

    // Balance-to-maxProfit ratio. Used to dynamically adjusts maxProfit based on balance.
    uint public balanceMaxProfitRatio = 24;

    // Funds that are locked in potentially winning bets. Prevents contract from committing to new bets that it cannot pay out.
    uint public lockedInBets;

    // Info of each bet.
    struct Bet {
        // Wager amount in wei.
        uint amount;
        // Modulo of a game.
        uint8 modulo;
        // Number of winning outcomes, used to compute winning payment (* modulo/rollUnder),
        // and used instead of mask for games with modulo > MAX_MASK_MODULO.
        uint8 rollUnder;
        // Bit mask representing winning bet outcomes (see MAX_MASK_MODULO comment).
        uint40 mask;
        // Block number of placeBet tx.
        uint placeBlockNumber;
        // Address of a gambler, used to pay out winning bets.
        address gambler;
        // Status of bet settlement.
        bool isSettled;
        // Outcome of bet.
        uint outcome;
        // Win amount.
        uint winAmount;
    }

    // Array of bets
    Bet[] public bets;

    // Mapping requestId returned by Chainlink VRF to bet Id.
    mapping(bytes32 => uint) public betMap;

    // Percentage of house edge fees to be rewarded to losing gambler.
    uint public rewardPct = 20;

    // Signed integer used for tracking house profit since inception.
    int public houseProfit;

    // Events
    event BetPlaced(uint indexed betId, address indexed gambler, uint amount, uint8 indexed modulo, uint8 rollUnder, uint40 mask);
    event BetSettled(uint indexed betId, address indexed gambler, uint amount, uint8 indexed modulo, uint8 rollUnder, uint40 mask, uint outcome, uint winAmount, uint rollReward);
    event BetRefunded(uint indexed betId, address indexed gambler, uint amount);

    // Constructor. Using Chainlink VRFConsumerBase constructor.
    constructor() VRFConsumerBase(VRF_COORDINATOR, LINK_TOKEN) public {}

    // See game token balance.
    function balance() external view returns (uint) {
        return IERC20(GAME_TOKEN).balanceOf(address(this));
    }

    // See number of bets.
    function betsLength() external view returns (uint) {
        return bets.length;
    }

    // Returns maximum profit allowed per bet. Prevents contract from accepting any bets with potential profit exceeding maxProfit.
    function maxProfit() public view returns (uint) {
        return IERC20(GAME_TOKEN).balanceOf(address(this)) / balanceMaxProfitRatio;
    }

    // Set balance-to-maxProfit ratio. 
    function setBalanceMaxProfitRatio(uint _balanceMaxProfitRatio) external onlyOwner {
        balanceMaxProfitRatio = _balanceMaxProfitRatio;
    }

    // Update Chainlink fee.
    function setChainlinkFee(uint _chainlinkFee) external onlyOwner {
        chainlinkFee = _chainlinkFee;
    }

    // Update Chainlink keyHash. Currently using keyHash with 10 block waiting time config. May configure to 64 block waiting time for more security.
    function setKeyHash(bytes32 _keyHash) external onlyOwner {
        keyHash = _keyHash;
    }

    // Set minimum bet amount. minBetAmount should be large enough such that its house edge fee can cover the Chainlink oracle fee.
    function setMinBetAmount(uint _minBetAmount) external onlyOwner {
        minBetAmount = _minBetAmount;
    }

    // Set maximum bet amount.
    function setMaxBetAmount(uint _maxBetAmount) external onlyOwner {
        maxBetAmount = _maxBetAmount;
    }

    // Set house edge.
    function setHouseEdgeBP(uint _houseEdgeBP) external onlyOwner {
        houseEdgeBP = _houseEdgeBP;
    }

    // Set wealth tax. Setting this to zero effectively disables wealth tax.
    function setWealthTaxBP(uint _wealthTaxBP) external onlyOwner {
        wealthTaxBP = _wealthTaxBP;
    }

    // Set threshold to trigger wealth tax.
    function setWealthTaxThreshold(uint _wealthTaxThreshold) external onlyOwner {
        wealthTaxThreshold = _wealthTaxThreshold;
    }

    // Set transaction mining contract address
    function setMiner(IMiner _miner) external onlyOwner {
        miner = _miner;
    }

    // Set transaction mining reward as a percentage of house edge fees.
    // Setting rewardPct to 100% effectively leads to an expectation value of 0.
    function setRewardPct(uint _rewardPct) external onlyOwner {
        require(_rewardPct <= 100, "rewardPct exceeds 100%");
        rewardPct = _rewardPct;
    }

    // Set maximum ROLL reward that a user can receive per bet.
    function setMaxReward(uint _maxReward) external onlyOwner {
        maxReward = _maxReward;
    }

    // Place bet
    function placeBet(uint256 amount, uint betMask, uint modulo, address referrer) external nonReentrant {

        // Validate input data.
        require(LINK.balanceOf(address(this)) >= chainlinkFee, "Insufficient LINK token");
        require(modulo > 1 && modulo <= MAX_MODULO, "Modulo not within range");
        require(amount >= minBetAmount && amount <= maxBetAmount, "Bet amount not within range");
        require(betMask > 0 && betMask < MAX_BET_MASK, "Mask not within range");

        // Transfer game token to contract
        IERC20(GAME_TOKEN).safeTransferFrom(address(msg.sender), address(this), amount);

        // Record referrer in Miner contract
        if (referrer != msg.sender) {
            miner.recordReferrer(msg.sender, referrer);
        }

        uint rollUnder;
        uint mask;

        if (modulo <= MAX_MASK_MODULO) {
            // Small modulo games can specify exact bet outcomes via bit mask.
            // rollUnder is a number of 1 bits in this mask (population count).
            // This magic looking formula is an efficient way to compute population
            // count on EVM for numbers below 2**40. 
            rollUnder = ((betMask * POPCNT_MULT) & POPCNT_MASK) % POPCNT_MODULO;
            mask = betMask;
        } else {
            // Larger modulos games specify the right edge of half-open interval of winning bet outcomes.
            require(betMask > 0 && betMask <= modulo, "betMask larger than modulo");
            rollUnder = betMask;
        }

        // Winning amount.
        uint possibleWinAmount = getWinAmount(amount, modulo, rollUnder);

        // Enforce max profit limit. Bet will not be placed if condition is not met.
        require(possibleWinAmount <= amount + maxProfit(), "maxProfit violation");

        // Check whether contract has enough funds to accept this bet.
        require(lockedInBets + possibleWinAmount <= IERC20(GAME_TOKEN).balanceOf(address(this)), "Insufficient funds");

        // Update lock funds.
        lockedInBets += possibleWinAmount;

        // Request random number from Chainlink VRF. Store requestId for validation checks later.
        bytes32 requestId = requestRandomness(keyHash, chainlinkFee, bets.length);

        // Map requestId to bet ID.
        betMap[requestId] = bets.length;
        
        // Record bet in event logs.
        emit BetPlaced(bets.length, msg.sender, amount, uint8(modulo), uint8(rollUnder), uint40(mask));

        // Store bet in bet list.
        bets.push(Bet(
            {
                amount: amount,
                modulo: uint8(modulo),
                rollUnder: uint8(rollUnder),
                mask: uint40(mask),
                placeBlockNumber: block.number,
                gambler: msg.sender,
                isSettled: false,
                outcome: 0,
                winAmount: 0
            }
        ));
    }

    // Returns the expected win amount.
    function getWinAmount(uint amount, uint modulo, uint rollUnder) private view returns (uint winAmount) {
        require(0 < rollUnder && rollUnder <= modulo, "Win probability out of range");
        uint houseEdgeFee = amount * (houseEdgeBP + getEffectiveWealthTaxBP(amount)) / 10000;
        winAmount = (amount - houseEdgeFee) * modulo / rollUnder;
    }

    // Get effective wealth tax for a given bet size.
    function getEffectiveWealthTaxBP(uint amount) private view returns (uint effectiveWealthTaxBP) {
        effectiveWealthTaxBP = amount / wealthTaxThreshold * wealthTaxBP;
    }

    // Expected ROLL tokens to be rewarded if lose bet.
    function getRollReward(uint amount, uint modulo, uint rollUnder) private view returns (uint) {
        // ROLL reward equals house edge fees, divided by win probability, multiplied by rewardPct.
        uint rollReward = amount * (houseEdgeBP + getEffectiveWealthTaxBP(amount)) / 10000 * modulo / (modulo - rollUnder) * rewardPct / 100;
        if (rollReward > maxReward) {
            rollReward = maxReward;
        }
        return rollReward;
    }

    // Callback function called by Chainlink VRF coordinator.
    function fulfillRandomness(bytes32 requestId, uint randomness) internal override {
        settleBet(requestId, randomness);
    }

    // Settle bet. Function can only be called by fulfillRandomness function, which in turn can only be called by Chainlink VRF.
    function settleBet(bytes32 requestId, uint randomNumber) internal nonReentrant {
        
        uint betId = betMap[requestId];
        Bet storage bet = bets[betId];
        uint amount = bet.amount;
        
        // Validation checks.
        require(amount > 0, "Bet does not exist");
        require(bet.isSettled == false, "Bet is settled already");

        // Fetch bet parameters into local variables (to save gas).
        uint modulo = bet.modulo;
        uint rollUnder = bet.rollUnder;
        address gambler = bet.gambler;

        // Do a roll by taking a modulo of random number.
        uint outcome = randomNumber % modulo;

        // Win amount if gambler wins this bet
        uint possibleWinAmount = getWinAmount(amount, modulo, rollUnder);

        // Roll reward if gambler loses this bet
        uint rollReward = getRollReward(amount, modulo, rollUnder);

        // Actual win amount by gambler.
        uint winAmount = 0;

        // Determine dice outcome.
        if (modulo <= MAX_MASK_MODULO) {
            // For small modulo games, check the outcome against a bit mask.
            if ((2 ** outcome) & bet.mask != 0) {
                winAmount = possibleWinAmount;
                rollReward = 0;
            }
        } else {
            // For larger modulos, check inclusion into half-open interval.
            if (outcome < rollUnder) {
                winAmount = possibleWinAmount;
                rollReward = 0;
            }
        }

        // Unlock possibleWinAmount from lockedInBets, regardless of the outcome.
        lockedInBets -= possibleWinAmount;

        // Update bet records
        bet.isSettled = true;
        bet.winAmount = winAmount;
        bet.outcome = outcome;

        // Send prize to winner, add ROLL reward to loser, and update house profit.
        if (winAmount > 0) {
            houseProfit -= int(winAmount - amount);
            IERC20(GAME_TOKEN).safeTransfer(address(gambler), winAmount);
        } else {
            houseProfit += int(amount);
            miner.addReward(gambler, rollReward);
        }

        // Record bet settlement in event log.
        emit BetSettled(betId, gambler, amount, uint8(modulo), uint8(rollUnder), bet.mask, outcome, winAmount, rollReward);
    }

    // Owner can withdraw funds not exceeding balance minus potential win amounts by open bets.
    function withdrawFunds(address beneficiary, uint withdrawAmount) external onlyOwner {
        require(withdrawAmount <= IERC20(GAME_TOKEN).balanceOf(address(this)) - lockedInBets, "Withdrawal exceeds limit");
        IERC20(GAME_TOKEN).safeTransfer(beneficiary, withdrawAmount);
    }
    
    // Owner can withdraw LINK tokens.
    function withdrawLink() external onlyOwner {
        IERC20(LINK_TOKEN).safeTransfer(owner(), IERC20(LINK_TOKEN).balanceOf(address(this)));
    }

    // Return the bet in the very unlikely scenario it was not settled by Chainlink VRF. 
    // In case you find yourself in a situation like this, just contact Polyroll support.
    // However, nothing precludes you from calling this method yourself.
    function refundBet(uint betId) external nonReentrant {
        
        Bet storage bet = bets[betId];
        uint amount = bet.amount;

        // Validation checks
        require(amount > 0, "Bet does not exist");
        require(bet.isSettled == false, "Bet is settled already");
        require(block.number > bet.placeBlockNumber + 21600, "Wait before requesting refund");

        uint possibleWinAmount = getWinAmount(amount, bet.modulo, bet.rollUnder);

        // Unlock possibleWinAmount from lockedInBets, regardless of the outcome.
        lockedInBets -= possibleWinAmount;

        // Update bet records
        bet.isSettled = true;
        bet.winAmount = amount;

        // Send the refund.
        IERC20(GAME_TOKEN).safeTransfer(address(bet.gambler), amount);

        // Record refund in event logs
        emit BetRefunded(betId, bet.gambler, amount);
    }
}