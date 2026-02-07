pragma solidity =0.6.6; // 升级到了 0.6.6

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
// TransferHelper 是一个非常重要的库！
// 它帮我们处理那些不标准的 ERC20 Token（比如 transfer 失败不报错，或者没有返回值的 Token）
import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

// 引入核心算法库（计算价格、滑点等）
import './libraries/UniswapV2Library.sol';
import './interfaces/IUniswapV2Router01.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';

contract UniswapV2Router01 is IUniswapV2Router01 {
    address public immutable override factory;
    address public immutable override WETH;

    // --- 核心修饰符：截止时间检查 ---
    // 防止矿工扣留交易。
    // 如果你发出一笔交易，想用 1 ETH 买 2000 USDT。
    // 矿工把你这笔交易扣留了 1 个小时，等 ETH 跌到 1000 USDT 时再打包。
    // 这时你 1 ETH 只能买 1000 USDT 了。
    // 有了 deadline，超过这个时间交易直接失败，保护用户。
    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'UniswapV2Router: EXPIRED');
        _;
    }

    constructor(address _factory, address _WETH) public {
        factory = _factory;
        WETH = _WETH;
    }

    // 只接收来自 WETH 合约的 ETH（用于 Unwrap WETH -> ETH）
    // 防止用户手滑直接把 ETH 转进 Router 导致丢失
    receive() external payable {
        assert(msg.sender == WETH); 
    }

    // ==================================================
    // PART 1: 添加流动性 (Add Liquidity)
    // ==================================================

    // 这是一个 private 函数，用来计算“最优添加比例”
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired, // 用户希望添加的 A 数量
        uint amountBDesired, // 用户希望添加的 B 数量
        uint amountAMin,     // 用户能接受的最少 A（滑点保护）
        uint amountBMin      // 用户能接受的最少 B
    ) private returns (uint amountA, uint amountB) {
        // 1. 如果池子不存在，顺手创建了
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);
        
        // 2. 如果是新池子，用户想存多少就存多少（定义初始价格）
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            // 3. 如果是老池子，必须按当前比例存入！
            // 计算：如果我存 amountADesired 个 A，需要配多少个 B？
            uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
            
            // 情况一：算出来的 B 小于等于用户愿意提供的 B
            if (amountBOptimal <= amountBDesired) {
                // 检查 B 的数量是否少于用户能接受的最小值
                require(amountBOptimal >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                // 情况二：B 不够，那就反过来算 A
                // 如果我存 amountBDesired 个 B，需要配多少个 A？
                uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    // 对外暴露的添加流动性接口
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        // 1. 计算出真正应该存多少 A 和 B
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        
        // 2. 获取 Pair 地址
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        
        // 3. 把币转给 Pair 合约
        // 注意：是 msg.sender -> Pair，不是 msg.sender -> Router -> Pair（省 Gas）
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        
        // 4. 调用 Pair 的 mint 发放 LP Token
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    // 添加 ETH 流动性的便捷函数 (自动包 WETH)
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external override payable ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
        // 先计算最优比例
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH, // 把 ETH 当作 WETH 处理
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        
        // 转 Token
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        
        // 把 ETH 包成 WETH
        IWETH(WETH).deposit{value: amountETH}();
        // 把 WETH 转给 Pair
        assert(IWETH(WETH).transfer(pair, amountETH));
        
        // 铸造 LP
        liquidity = IUniswapV2Pair(pair).mint(to);
        
        // 退还多余的 ETH (Dust Refund)
        // 用户可能发了 1 ETH，但只需要 0.8 ETH 配对，剩下 0.2 退回去
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // ==================================================
    // PART 2: 移除流动性 (Remove Liquidity)
    // ==================================================

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public override ensure(deadline) returns (uint amountA, uint amountB) {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        // 1. 把 LP Token 从用户转给 Pair (为了 burn)
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity); 
        // 2. 销毁 LP，Pair 会自动把 A 和 B 转给 to
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
        
        // 3. 排序并确认金额
        (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        
        // 4. 滑点检查：取出来的钱不能少于用户设置的最小值
        require(amountA >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
    }

    // ... (removeLiquidityETH 和 Permit 版本逻辑类似，略过以节省篇幅，主要是处理 WETH 解包和签名) ...

    // ==================================================
    // PART 3: 交易 (Swap) - 核心逻辑
    // ==================================================

    // 内部函数：执行多跳交易 A -> B -> C
    function _swap(uint[] memory amounts, address[] memory path, address _to) private {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            
            // 确定 amount0Out 和 amount1Out
            // 这是一个很精妙的写法：根据 token0/1 的顺序决定哪个是 0 哪个是 amountOut
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            
            // 确定接收者 to
            // 如果还没到终点，to 就是下一个 Pair 的地址；如果到了终点，to 就是用户指定的接收地址
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            
            // 执行 Swap
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output)).swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    // 场景：我有 100 USDT (Exact Input)，我想换尽可能多的 ETH
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external override ensure(deadline) returns (uint[] memory amounts) {
        // 1. 预计算：根据输入金额和路径，算出每一步能换多少钱
        // 比如：100 A -> 98 B -> 50 C
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        
        // 2. 滑点检查：最终拿到的 C 必须大于等于用户设置的最小值
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        
        // 3. 把第一步的代币 (A) 转给第一个 Pair
        TransferHelper.safeTransferFrom(path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]);
        
        // 4. 执行链式交换
        _swap(amounts, path, to);
    }

    // 场景：我一定要买 1 个 ETH (Exact Output)，我愿意支付不超过 2500 USDT
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external override ensure(deadline) returns (uint[] memory amounts) {
        // 1. 预计算：反向推导。要买 50 C，需要 98 B，需要 100 A
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        
        // 2. 滑点检查：第一步支付的 A 不能超过用户设置的最大值
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        
        // 3. 把第一步的代币 转给第一个 Pair
        TransferHelper.safeTransferFrom(path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]);
        
        // 4. 执行链式交换
        _swap(amounts, path, to);
    }

    // ... (ETH 相关的 Swap 函数逻辑类似，只是多了 WETH 的 deposit/withdraw) ...
}
