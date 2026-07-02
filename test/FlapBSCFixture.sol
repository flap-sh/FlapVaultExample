// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

interface IUniswapV2Router {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract MyVault is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // ----- 金库参数（初始化时设置） -----
    address public taxToken;         // 关联的 FlapTaxTokenV3 地址
    address public router;           // PancakeSwap 路由器
    address public wbnb;             // WBNB 地址

    // ----- 金库余额（BNB）-----
    uint256 public buybackReserveBNB;   // 回购金库余额
    uint256 public lotteryReserveBNB;   // 中奖金库余额

    // ----- 回购参数 -----
    uint256 public constant BUYBACK_RATE = 5;        // 每次消耗金库 5%
    uint256 public constant BUYBACK_INTERVAL = 60;   // 60 秒

    // ----- 抽奖参数 -----
    uint256 public constant LOTTERY_REWARD_RATE = 30; // 奖金池 30%
    uint256 public constant LOTTERY_TIMEOUT = 300;    // 5 分钟

    // ----- 买盘记录 -----
    struct BuyOrder {
        address buyer;
        uint256 timestamp;
    }
    BuyOrder public lastBuyOrder;

    // ----- 状态 -----
    uint256 public lastBuybackTime;

    // ----- 事件 -----
    event BuybackExecuted(uint256 bnbSpent, uint256 tokensBurned);
    event LotteryExecuted(address indexed winner, uint256 rewardBNB);
    event NewBuyOrder(address buyer, uint256 timestamp);

    // ----- 初始化函数（由 VaultFactory 调用）-----
    function initialize(
        address _taxToken,
        address _router,
        address _wbnb,
        address _owner
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        taxToken = _taxToken;
        router = _router;
        wbnb = _wbnb;
        transferOwnership(_owner);
    }

    // ----- 接收 BNB 税务分发（自动存入金库）-----
    receive() external payable {
        // Flap 的 TaxProcessor 会调用 dispatch() 将 BNB 发送到 vault 地址，
        // 我们需要按比例分配到两个金库（但 dispatch 是批量发送，我们无法区分来源）
        // 解决方案：在 receive 中将所有收到的 BNB 暂存，然后由 keeper 调用 allocateFunds() 分配，
        // 或者我们直接累加到一个池子，然后在回购/抽奖时按比例消耗。
        // 更简单：我们设一个 totalReserve，然后分别按 80/20 分配。
        // 但 dispatch 可能多次调用，我们需记录每笔，但实际 Flap 的 TaxProcessor 是一次性发送所有市场收入。
        // 所以我们可以直接在 receive 中按比例分配：
        uint256 amount = msg.value;
        buybackReserveBNB += (amount * 80) / 100;
        lotteryReserveBNB += (amount * 20) / 100;
    }

    // ----- 更新买盘记录（由前端或keeper 通过监听交易调用，或直接在代币合约中回调）-----
    // 因为代币合约的买卖事件无法直接调用本合约，我们提供一个外部函数，由后端监听买入事件后调用。
    // 注意：此函数应只允许可信地址（如 keeper）调用，防止恶意篡改。
    function recordBuy(address buyer) external onlyOwner {
        lastBuyOrder = BuyOrder(buyer, block.timestamp);
        emit NewBuyOrder(buyer, block.timestamp);
    }

    // ----- 回购销毁（使用 BNB 买入并销毁本代币）-----
    function executeBuyback(uint256 amountOutMin) external onlyOwner nonReentrant {
        require(block.timestamp >= lastBuybackTime + BUYBACK_INTERVAL, "Too soon");
        uint256 bnbToSpend = (buybackReserveBNB * BUYBACK_RATE) / 100;
        require(bnbToSpend > 0, "No reserve");

        buybackReserveBNB -= bnbToSpend;

        address[] memory path = new address[](2);
        path[0] = wbnb;
        path[1] = taxToken;

        uint256 beforeBalance = IERC20(taxToken).balanceOf(address(this));

        IUniswapV2Router(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnbToSpend}(
            amountOutMin,
            path,
            address(this),
            block.timestamp + 300
        );

        uint256 tokensBought = IERC20(taxToken).balanceOf(address(this)) - beforeBalance;
        // 销毁买入的代币（需代币合约有销毁权限或调用 burn）
        // 注意：FlapTaxTokenV3 有 burn 函数（需 owner 或授权），我们直接调用 taxToken 的 burn
        IFlapTaxTokenV3(taxToken).burn(tokensBought);

        lastBuybackTime = block.timestamp;
        emit BuybackExecuted(bnbToSpend, tokensBought);
    }

    // ----- 幸运抽奖（奖励 BNB）-----
    function executeLottery() external onlyOwner nonReentrant {
        require(block.timestamp >= lastBuyOrder.timestamp + LOTTERY_TIMEOUT, "Not timeout");
        require(lastBuyOrder.buyer != address(0), "No buyer");

        address winner = lastBuyOrder.buyer;
        uint256 reward = (lotteryReserveBNB * LOTTERY_REWARD_RATE) / 100;
        require(reward > 0, "No reward");

        lotteryReserveBNB -= reward;
        delete lastBuyOrder;

        (bool sent, ) = winner.call{value: reward}("");
        require(sent, "Transfer failed");

        emit LotteryExecuted(winner, reward);
    }

    // ----- 紧急提取（仅 owner，用于意外情况）-----
    function emergencyWithdrawBNB(address to) external onlyOwner {
        uint256 amount = address(this).balance;
        (bool sent, ) = to.call{value: amount}("");
        require(sent, "Withdraw failed");
    }
}

interface IFlapTaxTokenV3 {
    function burn(uint256 amount) external;
}
