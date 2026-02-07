pragma solidity =0.6.6; // Router 使用了比 Core (0.5.16) 更新的编译器版本

// 引入 Core 仓库的 Factory 接口，用于创建 Pair 或查询 Pair 地址
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';

// 引入 TransferHelper 库
// 这是一个安全库，专门用来处理那些不标准的 ERC20 代币（例如 USDT）。
// 因为有些代币转账失败时不报错，或者没有返回值，直接调用 .transfer 会有风险。
import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

// 引入本地的 Library（数学库）、Router 接口、ERC20 接口和 WETH 接口
import './libraries/UniswapV2Library.sol';
import './interfaces/IUniswapV2Router01.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';

contract UniswapV2Router01 is IUniswapV2Router01 {
    // 状态变量定义
    // immutable 是 Solidity 0.6 的新特性。
    // 它们在构造函数赋值后就变成常量（写入字节码），读取时不需要读取存储槽（SLOAD），非常省 Gas。
    address public immutable override factory;
    address public immutable override WETH;

    // 修饰符：确保交易在截止时间 (deadline) 前被打包
    // 作用：防止矿工恶意扣留交易，等到价格变差了再打包（MEV 保护）。
    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'UniswapV2Router: EXPIRED');
        _;
    }

    constructor(address _factory, address _WETH) public {
        factory = _factory;
        WETH = _WETH;
    }

    // 接收 ETH 的函数
    // 逻辑：只接受来自 WETH 合约解包出来的 ETH。
    // 目的：防止用户手滑直接把 ETH 转给 Router 合约（Router 没有提款功能，转进来就丢了）。
    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    // **** 添加流动性 (ADD LIQUIDITY) ****
    
    // 内部函数：计算添加流动性的“最优比例”
    // 因为 Pair 里的价格由储备量比例决定，用户必须按当前比例存入，否则会被套利。
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired, // 用户希望存入 A 的数量
        uint amountBDesired, // 用户希望存入 B 的数量
        uint amountAMin,     // 用户能接受的最少 A（滑点保护）
        uint amountBMin      // 用户能接受的最少 B
    ) private returns (uint amountA, uint amountB) {
        // 1. 如果池子还不存在，Router 顺手帮忙创建了（用户体验优化）
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        
        // 2. 获取当前池子的储备量
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);
        
        // 3. 分支一：这是一个新池子
        if (reserveA == 0 && reserveB == 0) {
            // 新池子没有价格，用户存多少就是多少（由第一个人定义初始价格）
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            // 4. 分支二：这是一个老池子
            // 计算最优的 B 数量：如果我存 Desired A，需要配多少 B？
            uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
            
            // 如果算出来的 B <= 用户愿意给的 B，说明 B 够用
            if (amountBOptimal <= amountBDesired) {
                // 检查 B 是否满足最小值限制
                require(amountBOptimal >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                // 如果 B 不够用，那就反过来算 A
                // 如果我存 Desired B，需要配多少 A？
                uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
                // 这里的 A 一定 <= Desired A
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    // 外部接口：两个 ERC20 代币添加流动性
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
        // 1. 计算真正应该存入多少钱
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        
        // 2. 计算 Pair 地址（使用 create2 预测，省 Gas）
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        
        // 3. 将代币从用户钱包直接转给 Pair 合约
        // 注意：资金不经过 Router 中转，直接点对点传输，更安全且省 Gas
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        
        // 4. 调用 Pair 的 mint 函数，给 to 地址铸造 LP Token
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    // 外部接口：ETH + ERC20 添加流动性
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external override payable ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
        // 1. 计算最优比例（把 ETH 当作 WETH 处理）
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value, // 用户发送的 ETH 数量
            amountTokenMin,
            amountETHMin
        );
        
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        
        // 2. 转 ERC20 代币给 Pair
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        
        // 3. 处理 ETH 逻辑
        // 先把 ETH 存入 WETH 合约，换成 WETH
        IWETH(WETH).deposit{value: amountETH}();
        // 再把 WETH 转给 Pair 合约
        assert(IWETH(WETH).transfer(pair, amountETH));
        
        // 4. 铸造 LP Token
        liquidity = IUniswapV2Pair(pair).mint(to);
        
        // 5. 退还多余的 ETH (Dust Refund)
        // 用户可能发了 1 ETH，但最优比例只需要 0.8 ETH，剩下 0.2 退回去
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH); 
    }

    // **** 移除流动性 (REMOVE LIQUIDITY) ****

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity, // 要销毁的 LP Token 数量
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public override ensure(deadline) returns (uint amountA, uint amountB) {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        
        // 1. 把 LP Token 从用户转给 Pair
        // 这一步需要用户先 Approve Router，Router 再 transferFrom 用户到 Pair
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        
        // 2. 销毁 LP，取出底层资产
        // amount0/1 是按 Pair 内代币地址排序返回的
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
        
        // 3. 排序匹配
        // 这一步是为了让返回值 amountA/B 对应参数里的 tokenA/B
        (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        
        // 4. 滑点检查
        require(amountA >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
    }

    // 移除流动性：ETH + ERC20
    // 逻辑：先调用上面的 removeLiquidity 把 WETH 取出来，再解包成 ETH 给用户
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public override ensure(deadline) returns (uint amountToken, uint amountETH) {
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this), // 注意：先发给 Router 自己，方便解包
            deadline
        );
        
        // 把 ERC20 转给用户
        TransferHelper.safeTransfer(token, to, amountToken);
        
        // 把 WETH 换成 ETH
        IWETH(WETH).withdraw(amountETH);
        
        // 把 ETH 转给用户
        TransferHelper.safeTransferETH(to, amountETH);
    }

    // 带签名的移除流动性 (Permit)
    // 区别在于：不需要先发 approve 交易，而是传入一个签名，Router 帮用户提交签名
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external override returns (uint amountA, uint amountB) {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        
        // 如果 approveMax 为真，则授权最大值，否则只授权 liquidity 数量
        uint value = approveMax ? uint(-1) : liquidity;
        
        // 1. 提交签名，让 Pair 批准 Router 动用用户的 LP Token
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        
        // 2. 执行移除逻辑
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    // 同上，ETH 版本
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external override returns (uint amountToken, uint amountETH) {
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        uint value = approveMax ? uint(-1) : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // **** 交易 (SWAP) ****

    // 内部函数：执行多跳路径交易 (A -> B -> C)
    // 前提：初始金额已经转入了第一个 Pair
    function _swap(uint[] memory amounts, address[] memory path, address _to) private {
        for (uint i; i < path.length - 1; i++) {
            // 获取当前这一跳的输入和输出代币地址
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            uint amountOut = amounts[i + 1]; // 下一跳应该收到的钱
            
            // 确定调用 Pair.swap 时，哪一个是 0，哪一个是 amountOut
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            
            // 核心路由逻辑：
            // 如果还没到终点，接收者 (to) 就是下一个 Pair 的地址
            // 如果到了终点，接收者就是用户指定的 _to
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            
            // 执行 Swap，不使用闪电贷回调 (new bytes(0))
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output)).swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    // 场景：用确定的输入，换取尽可能多的输出 (Exact Input)
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external override ensure(deadline) returns (uint[] memory amounts) {
        // 1. 预计算：根据输入金额，算出路径上每一步能换多少钱
        // 比如 100 A -> 98 B -> 50 C
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        
        // 2. 滑点检查：最终拿到的钱必须 >= 用户设定的最小值
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        
        // 3. 第一步推力：把用户的代币转给第一个 Pair
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        
        // 4. 开始多跳交易循环
        _swap(amounts, path, to);
    }

    // 场景：用尽可能少的输入，换取确定的输出 (Exact Output)
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external override ensure(deadline) returns (uint[] memory amounts) {
        // 1. 预计算：反向推导。要买 50 C，需要 98 B，需要 100 A
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        
        // 2. 滑点检查：第一步支付的 A 必须 <= 用户设定的最大值
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        
        // 3. 第一步推力
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        
        // 4. 交易循环
        _swap(amounts, path, to);
    }

    // 场景：用 ETH 买 Token (Exact Input)
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        // 路径检查：起点必须是 WETH
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        
        amounts = UniswapV2Library.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        
        // 把用户的 ETH 包成 WETH
        IWETH(WETH).deposit{value: amounts[0]}();
        // 把 WETH 转给第一个 Pair
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        
        _swap(amounts, path, to);
    }

    // 场景：用 Token 买 ETH (Exact Output)
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        // 路径检查：终点必须是 WETH
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        
        // 接收者是 Router 自己 (address(this))，因为要解包 WETH
        _swap(amounts, path, address(this));
        
        // Router 把收到的 WETH 解包成 ETH
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        // 把 ETH 转给用户
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    // 场景：用 Token 买 ETH (Exact Input)
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    // 场景：用 ETH 买 Token (Exact Output)
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        
        _swap(amounts, path, to);
        
        // 退还多余的 ETH (Dust Refund)
        // 用户可能发了 1 ETH，但买这些币只需要 0.8 ETH，剩下 0.2 退回
        if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // **** 库函数包装 (LIBRARY FUNCTIONS) ****
    // 把 Library 的函数暴露出来，方便前端直接调用 Router 查询价格
    
    function quote(uint amountA, uint reserveA, uint reserveB) public pure override returns (uint amountB) {
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) public pure override returns (uint amountOut) {
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) public pure override returns (uint amountIn) {
        return UniswapV2Library.getAmountOut(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(uint amountIn, address[] memory path) public view override returns (uint[] memory amounts) {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint amountOut, address[] memory path) public view override returns (uint[] memory amounts) {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }
}
