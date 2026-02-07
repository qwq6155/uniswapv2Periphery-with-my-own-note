pragma solidity =0.6.6;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
// FixedPoint 库：用于处理高精度定点数运算
// 因为价格可能是很小的小数，Solidity 不支持浮点数，必须用定点数
import '@uniswap/lib/contracts/libraries/FixedPoint.sol';

import '../libraries/UniswapV2OracleLibrary.sol';
import '../libraries/UniswapV2Library.sol';

// 固定窗口预言机：每隔一个周期（PERIOD）重新计算一次该周期的平均价格
contract ExampleOracleSimple {
    // 为所有类型使用 FixedPoint 库的方法
    using FixedPoint for *;

    // 周期设为 24 小时。
    // 这意味着价格每天更新一次，反映的是过去 24 小时的平均水平。
    uint public constant PERIOD = 24 hours;

    IUniswapV2Pair immutable pair;
    address public immutable token0;
    address public immutable token1;

    // 记录上一次更新时的累积价格快照
    uint    public price0CumulativeLast;
    uint    public price1CumulativeLast;
    // 记录上一次更新的时间戳
    uint32  public blockTimestampLast;
    
    // 存储计算出来的平均价格
    // uq112x112 是 FixedPoint 库定义的一种数据结构，用于存储高精度价格
    FixedPoint.uq112x112 public price0Average;
    FixedPoint.uq112x112 public price1Average;

    constructor(address factory, address tokenA, address tokenB) public {
        IUniswapV2Pair _pair = IUniswapV2Pair(UniswapV2Library.pairFor(factory, tokenA, tokenB));
        pair = _pair;
        token0 = _pair.token0();
        token1 = _pair.token1();
        
        // --- 初始化快照 ---
        // 在合约部署时，记录当前的累积价格和时间
        // priceCumulativeLast 是 Uniswap V2 Pair 原生存储的一个只会一直增加的大数
        price0CumulativeLast = _pair.price0CumulativeLast(); 
        price1CumulativeLast = _pair.price1CumulativeLast(); 
        
        uint112 reserve0;
        uint112 reserve1;
        (reserve0, reserve1, blockTimestampLast) = _pair.getReserves();
        require(reserve0 != 0 && reserve1 != 0, 'ExampleOracleSimple: NO_RESERVES'); // 确保池子里有流动性
    }

    // --- 核心函数：更新价格 ---
    // 这个函数必须由外部调用（可以是任何人，通常是机器人的定时脚本）
    // 只有距离上次更新超过 24 小时后，调用才有效
    function update() external {
        // 1. 获取“当前”的累积价格
        // 注意：这里没有直接调用 pair.price0CumulativeLast()，而是用了 UniswapV2OracleLibrary。
        // 为什么？因为 Pair 合约里的 cumulativeLast 只在区块开始的第一笔交易前更新。
        // OracleLibrary 会帮我们算出“截至到当前区块当前秒”的最新累积值，精度更高。
        (uint price0Cumulative, uint price1Cumulative, uint32 blockTimestamp) =
            UniswapV2OracleLibrary.currentCumulativePrices(address(pair));
            
        // 2. 计算时间差
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired (模运算会自动处理溢出)

        // 3. 检查是否满足更新周期
        // 必须等够 24 小时才能更新一次平均价
        require(timeElapsed >= PERIOD, 'ExampleOracleSimple: PERIOD_NOT_ELAPSED');

        // 4. 计算平均价格 (TWAP)
        // 公式：(现在的累积值 - 上次的累积值) / 时间差
        // 就像你在高速公路上：(终点里程 - 起点里程) / 用时 = 平均速度
        
        // FixedPoint.uq112x112(...) 把结果转换成定点数格式存储
        // uint224(...) 是因为累积值差值可能很大，需要转一下类型
        price0Average = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed));
        price1Average = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed));

        // 5. 更新快照，为下一个 24 小时做准备
        price0CumulativeLast = price0Cumulative;
        price1CumulativeLast = price1Cumulative;
        blockTimestampLast = blockTimestamp;
    }

    // --- 读价格函数 (Consult) ---
    // 外部合约调用这个函数来查询价格
    // amountIn: 输入多少个代币
    // amountOut: 根据 TWAP 算出值多少个另一个代币
    function consult(address token, uint amountIn) external view returns (uint amountOut) {
        if (token == token0) {
            // 使用存储的平均价 price0Average 乘以 输入数量
            // decode144 是把定点数转换回普通整数
            amountOut = price0Average.mul(amountIn).decode144();
        } else {
            require(token == token1, 'ExampleOracleSimple: INVALID_TOKEN');
            amountOut = price1Average.mul(amountIn).decode144();
        }
    }
}
