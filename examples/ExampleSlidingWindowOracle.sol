pragma solidity =0.6.6;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/lib/contracts/libraries/FixedPoint.sol';

import '../libraries/SafeMath.sol';
import '../libraries/UniswapV2Library.sol';
import '../libraries/UniswapV2OracleLibrary.sol';

// 滑动窗口预言机
// 这是一个单例合约 (Singleton)。意味着你只需要部署一次，
// 就可以为无数个交易对提供服务（只要它们需要的 windowSize 和 granularity 是一样的）。
// 相比之下，ExampleOracleSimple 需要为每个 Pair 单独部署一个。
contract ExampleSlidingWindowOracle {
    using FixedPoint for *;
    using SafeMath for uint;

    // 观察点结构体：存储某个时刻的累积价格
    struct Observation {
        uint timestamp;
        uint price0Cumulative;
        uint price1Cumulative;
    }

    address public immutable factory;
    
    // 窗口总大小 (例如：24小时 = 86400秒)
    uint public immutable windowSize;
    
    // 粒度：把窗口分成多少个格子 (例如：24个)
    // 粒度越高，价格越平滑，但需要的 Gas 越多（因为要频繁调用 update）
    uint8 public immutable granularity;
    
    // 周期大小：每个格子代表多长时间 (例如：1小时 = 3600秒)
    // periodSize = windowSize / granularity
    uint public immutable periodSize;

    // 核心存储：Pair地址 => 观察点数组 (Circular Buffer)
    // 这个数组的长度固定为 granularity
    mapping(address => Observation[]) public pairObservations;

    constructor(address factory_, uint windowSize_, uint8 granularity_) public {
        require(granularity_ > 1, 'SlidingWindowOracle: GRANULARITY');
        // 确保窗口能被粒度整除
        require(
            (periodSize = windowSize_ / granularity_) * granularity_ == windowSize_,
            'SlidingWindowOracle: WINDOW_NOT_EVENLY_DIVISIBLE'
        );
        factory = factory_;
        windowSize = windowSize_;
        granularity = granularity_;
    }

    // --- 核心算法：时间映射 ---
    // 输入一个时间戳，计算它应该落在数组的第几个格子 (0 到 granularity-1)
    // 算法：(时间戳 / 单个周期秒数) % 总格子数
    function observationIndexOf(uint timestamp) public view returns (uint8 index) {
        uint epochPeriod = timestamp / periodSize;
        return uint8(epochPeriod % granularity);
    }

    // --- 核心算法：找最老的数据 ---
    // 如果当前指针在 Index 5，那么在一个满的环形数组里，最老的数据就在 Index 6。
    // 原理：(currentIndex + 1) % granularity
    function getFirstObservationInWindow(address pair) private view returns (Observation storage firstObservation) {
        uint8 observationIndex = observationIndexOf(block.timestamp);
        // 计算“下一个”索引，在环形缓冲区里，当前索引的“下一个”就是“最老”的那个
        uint8 firstObservationIndex = (observationIndex + 1) % granularity;
        firstObservation = pairObservations[pair][firstObservationIndex];
    }

    // --- 写数据 (Update) ---
    // 任何人都可以调用。通常由机器人在套利或交易前调用，或者专门的 Keeper 定时调用。
    function update(address tokenA, address tokenB) external {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);

        // 1. 初始化数组 (仅在第一次调用时执行)
        // 把数组长度撑大到 granularity (例如 24)
        for (uint i = pairObservations[pair].length; i < granularity; i++) {
            pairObservations[pair].push();
        }

        // 2. 计算当前时间对应的格子索引
        uint8 observationIndex = observationIndexOf(block.timestamp);
        Observation storage observation = pairObservations[pair][observationIndex];

        // 3. 检查这个格子里的数据是否陈旧
        // 我们只希望每个周期 (periodSize) 更新一次这个格子。
        // 如果这个格子里的 timestamp 是很久以前的（比如上一轮循环留下的，或者初始化的 0），就更新它。
        uint timeElapsed = block.timestamp - observation.timestamp;
        if (timeElapsed > periodSize) {
            (uint price0Cumulative, uint price1Cumulative,) = UniswapV2OracleLibrary.currentCumulativePrices(pair);
            observation.timestamp = block.timestamp;
            observation.price0Cumulative = price0Cumulative;
            observation.price1Cumulative = price1Cumulative;
        }
    }

    // --- 辅助计算：算平均价 ---
    // (结束累积值 - 开始累积值) / 时间差
    function computeAmountOut(
        uint priceCumulativeStart, uint priceCumulativeEnd,
        uint timeElapsed, uint amountIn
    ) private pure returns (uint amountOut) {
        // overflow is desired (累积值溢出是预期的)
        FixedPoint.uq112x112 memory priceAverage = FixedPoint.uq112x112(
            uint224((priceCumulativeEnd - priceCumulativeStart) / timeElapsed)
        );
        amountOut = priceAverage.mul(amountIn).decode144();
    }

    // --- 读数据 (Consult) ---
    // 计算 TWAP。
    // 逻辑：拿“当前累积值” - “24小时前那个格子的累积值”，算出24小时平均价。
    function consult(address tokenIn, uint amountIn, address tokenOut) external view returns (uint amountOut) {
        address pair = UniswapV2Library.pairFor(factory, tokenIn, tokenOut);
        
        // 1. 获取最老的观察点 (大约 24 小时前的数据)
        Observation storage firstObservation = getFirstObservationInWindow(pair);

        uint timeElapsed = block.timestamp - firstObservation.timestamp;
        
        // 2. 安全检查
        // 确保最老的数据确实是在窗口范围内。
        // 如果 timeElapsed > windowSize，说明这个 Pair 已经很久没人 update 了，数据太老，失效。
        require(timeElapsed <= windowSize, 'SlidingWindowOracle: MISSING_HISTORICAL_OBSERVATION');
        // 确保数据足够“老”。如果数据太新，说明窗口还没填满，或者 update 频率不对。
        require(timeElapsed >= windowSize - periodSize * 2, 'SlidingWindowOracle: UNEXPECTED_TIME_ELAPSED');

        // 3. 获取当前的累积值
        (uint price0Cumulative, uint price1Cumulative,) = UniswapV2OracleLibrary.currentCumulativePrices(pair);
        (address token0,) = UniswapV2Library.sortTokens(tokenIn, tokenOut);

        // 4. 计算平均价
        if (token0 == tokenIn) {
            return computeAmountOut(firstObservation.price0Cumulative, price0Cumulative, timeElapsed, amountIn);
        } else {
            return computeAmountOut(firstObservation.price1Cumulative, price1Cumulative, timeElapsed, amountIn);
        }
    }
}
