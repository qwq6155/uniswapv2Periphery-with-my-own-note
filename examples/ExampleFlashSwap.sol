pragma solidity =0.6.6;

// 引入 V2 的 Callee 接口。必须实现这个接口才能接收闪电贷回调。
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Callee.sol';

import '../libraries/UniswapV2Library.sol';
import '../interfaces/V1/IUniswapV1Factory.sol';
import '../interfaces/V1/IUniswapV1Exchange.sol';
import '../interfaces/IUniswapV2Router01.sol';
import '../interfaces/IERC20.sol';
import '../interfaces/IWETH.sol';

// 继承 IUniswapV2Callee 接口
contract ExampleFlashSwap is IUniswapV2Callee {
    // 状态变量：记录 V1 工厂、V2 工厂、WETH 地址
    IUniswapV1Factory immutable factoryV1;
    address immutable factory;
    IWETH immutable WETH;

    constructor(address _factory, address _factoryV1, address router) public {
        factoryV1 = IUniswapV1Factory(_factoryV1);
        factory = _factory;
        WETH = IWETH(IUniswapV2Router01(router).WETH());
    }

    // 接收 ETH 的函数
    // 因为我们要和 V1 交互，V1 发送的是原生 ETH，所以必须能接收。
    receive() external payable {}

    // --- 核心回调函数 ---
    // 当你在 V2 Pair 合约调用 swap 并且 data 不为空时，Pair 会自动调用这个函数。
    // 此时，钱已经借给你了，你必须在这个函数结束前还回去。
    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external override {
        address[] memory path = new address[](2);
        uint amountToken;
        uint amountETH;
        
        // 1. 验证调用者身份 & 解析借贷数据
        { 
            address token0 = IUniswapV2Pair(msg.sender).token0();
            address token1 = IUniswapV2Pair(msg.sender).token1();
            // 安全检查：必须由官方 V2 Pair 调用，防止被黑客假冒 Pair 调用
            assert(msg.sender == UniswapV2Library.pairFor(factory, token0, token1)); 
            
            // 确保只借了一种币（单向套利）
            assert(amount0 == 0 || amount1 == 0); 
            
            path[0] = amount0 == 0 ? token0 : token1;
            path[1] = amount0 == 0 ? token1 : token0;
            
            // 确定借的是 Token 还是 WETH
            amountToken = token0 == address(WETH) ? amount1 : amount0;
            amountETH = token0 == address(WETH) ? amount0 : amount1;
        }

        // 策略限制：本示例只演示 V2 WETH Pair 和 V1 ETH Pair 之间的套利
        assert(path[0] == address(WETH) || path[1] == address(WETH)); 
        
        // 获取 ERC20 Token 地址（非 WETH 的那个）
        IERC20 token = IERC20(path[0] == address(WETH) ? path[1] : path[0]);
        // 获取该 Token 在 V1 的交易所地址
        IUniswapV1Exchange exchangeV1 = IUniswapV1Exchange(factoryV1.getExchange(address(token))); 

        // 2. 执行套利逻辑
        if (amountToken > 0) {
            // 场景 A: 从 V2 借了 Token，去 V1 卖成 ETH
            // 此时 V2 的 Token 价格 < V1 的 Token 价格
            
            (uint minETH) = abi.decode(data, (uint)); // 解析调用者传入的滑点参数
            
            // 授权 V1 交易所动用我们的 Token
            token.approve(address(exchangeV1), amountToken);
            
            // 在 V1 卖掉所有借来的 Token，换回 ETH
            uint amountReceived = exchangeV1.tokenToEthSwapInput(amountToken, minETH, uint(-1));
            
            // 计算需要还给 V2 多少 WETH
            // getAmountsIn: 如果我要借 amountToken，我需要支付多少 WETH？
            uint amountRequired = UniswapV2Library.getAmountsIn(factory, amountToken, path)[0];
            
            // 检查：赚的钱是否够还债？(amountReceived 是 ETH, amountRequired 是 WETH)
            assert(amountReceived > amountRequired); 
            
            // 把还债部分的 ETH 包成 WETH
            WETH.deposit{value: amountRequired}();
            
            // 还给 V2 Pair (还的是 WETH)
            assert(WETH.transfer(msg.sender, amountRequired)); 
            
            // 剩下的 ETH 就是利润！直接转给 sender (触发交易的人)
            (bool success,) = sender.call{value: amountReceived - amountRequired}(new bytes(0)); 
            assert(success);
        } else {
            // 场景 B: 从 V2 借了 WETH，去 V1 买 Token
            // 此时 V2 的 Token 价格 > V1 的 Token 价格
            
            (uint minTokens) = abi.decode(data, (uint)); 
            
            // 把借来的 WETH 解包成 ETH (因为 V1 只收 ETH)
            WETH.withdraw(amountETH);
            
            // 在 V1 用 ETH 买入 Token
            uint amountReceived = exchangeV1.ethToTokenSwapInput{value: amountETH}(minTokens, uint(-1));
            
            // 计算需要还给 V2 多少 Token
            uint amountRequired = UniswapV2Library.getAmountsIn(factory, amountETH, path)[0];
            
            // 检查利润
            assert(amountReceived > amountRequired); 
            
            // 还给 V2 Pair (还的是 Token)
            assert(token.transfer(msg.sender, amountRequired)); 
            
            // 剩下的 Token 就是利润！转给 sender
            assert(token.transfer(sender, amountReceived - amountRequired)); 
        }
    }
}
