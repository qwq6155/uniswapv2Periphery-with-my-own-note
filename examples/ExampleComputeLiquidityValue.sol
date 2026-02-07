pragma solidity =0.6.6;

// 引入核心数学库：UniswapV2LiquidityMathLibrary
// 这个库不在核心仓库，而是在周边仓库 (Periphery) 或示例仓库中，专门用于处理复杂的流动性估值
import '../libraries/UniswapV2LiquidityMathLibrary.sol';

contract ExampleComputeLiquidityValue {
    using SafeMath for uint256;

    // 工厂合约地址，用于查找 Pair
    address public immutable factory;

    constructor(address factory_) public {
        factory = factory_;
    }

    // **** 功能 1: 计算套利后的储备量 ****
    // 场景：Uniswap 上的价格是 1 ETH = 2000 USDT，但外部市场（币安）是 1 ETH = 2100 USDT。
    // 套利者会来 Uniswap 买 ETH，直到价格变成 2100。
    // 这个函数就是计算：当价格被套利者抹平后，池子里的 reserveA 和 reserveB 会变成多少？
    function getReservesAfterArbitrage(
        address tokenA,
        address tokenB,
        uint256 truePriceTokenA, // 外部市场的真实价格 A
        uint256 truePriceTokenB  // 外部市场的真实价格 B
    ) external view returns (uint256 reserveA, uint256 reserveB) {
        // 直接调用库函数计算
        return UniswapV2LiquidityMathLibrary.getReservesAfterArbitrage(
            factory,
            tokenA,
            tokenB,
            truePriceTokenA,
            truePriceTokenB
        );
    }

    // **** 功能 2: 计算当前流动性价值 ****
    // 场景：我有 10 个 LP Token，想知道它们现在对应多少 Token A 和 Token B。
    // 这比简单的 (balance / totalSupply) * reserve 要复杂一点，因为还要考虑 kLast 和 fee 的增长
    function getLiquidityValue(
        address tokenA,
        address tokenB,
        uint256 liquidityAmount // 我持有的 LP Token 数量
    ) external view returns (
        uint256 tokenAAmount,
        uint256 tokenBAmount
    ) {
        return UniswapV2LiquidityMathLibrary.getLiquidityValue(
            factory,
            tokenA,
            tokenB,
            liquidityAmount
        );
    }

    // **** 功能 3: 计算套利后的流动性价值 ****
    // 这是一个非常高级的预测功能！
    // 场景：我是 LP，我想退出流动性。但我发现 Uniswap 价格偏离了市场价。
    // 我知道套利者马上就会来搬砖，池子的储备量会变，fee 也会增加。
    // 这个函数帮我算出：等套利者搬完砖后，我手里的 LP Token 到底值多少钱？
    // 这通常比当前直接退出的价值要高（因为赚了套利者的交易费）。
    function getLiquidityValueAfterArbitrageToPrice(
        address tokenA,
        address tokenB,
        uint256 truePriceTokenA,
        uint256 truePriceTokenB,
        uint256 liquidityAmount
    ) external view returns (
        uint256 tokenAAmount,
        uint256 tokenBAmount
    ) {
        return UniswapV2LiquidityMathLibrary.getLiquidityValueAfterArbitrageToPrice(
            factory,
            tokenA,
            tokenB,
            truePriceTokenA,
            truePriceTokenB,
            liquidityAmount
        );
    }

    // **** 辅助功能: Gas 费测试 ****
    // 开发者用来测试上面那个复杂数学计算到底要消耗多少 Gas
    // view 函数通常不消耗 Gas（如果是 eth_call），但如果被其他合约调用就会消耗。
    function getGasCostOfGetLiquidityValueAfterArbitrageToPrice(
        address tokenA,
        address tokenB,
        uint256 truePriceTokenA,
        uint256 truePriceTokenB,
        uint256 liquidityAmount
    ) external view returns (
        uint256
    ) {
        // 记录开始时的剩余 Gas
        uint gasBefore = gasleft();
        
        // 执行计算
        UniswapV2LiquidityMathLibrary.getLiquidityValueAfterArbitrageToPrice(
            factory,
            tokenA,
            tokenB,
            truePriceTokenA,
            truePriceTokenB,
            liquidityAmount
        );
        
        // 记录结束时的剩余 Gas
        uint gasAfter = gasleft();
        
        // 差值就是消耗的 Gas
        return gasBefore - gasAfter;
    }
}
