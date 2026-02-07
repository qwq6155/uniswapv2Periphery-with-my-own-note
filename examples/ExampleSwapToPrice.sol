pragma solidity =0.6.6; // 指定 Solidity 编译器版本，0.6.x 引入了 immutable 和 receive 等新特性

// 引入 Core 仓库的接口，用于与 Factory 交互（如创建 Pair、查询 Pair 地址）
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
// 引入安全转账库。这是为了兼容不标准的 ERC20 代币（如 USDT），防止转账失败不报错的情况
import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

// 引入 Router02 自身的接口定义
import './interfaces/IUniswapV2Router02.sol';
// 引入核心算法库（计算价格、储备量、最优路径金额等）
import './libraries/UniswapV2Library.sol';
// 引入安全数学库（防止整数溢出，Solidity 0.8 之前必备）
import './libraries/SafeMath.sol';
// 引入 ERC20 和 WETH 标准接口
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';

contract UniswapV2Router02 is IUniswapV2Router02 {
    using SafeMath for uint; // 为 uint 类型启用 SafeMath 方法（如 .add, .sub）

    // 定义不可变变量 (immutable)。
    // 它们在构造函数赋值后就直接写入字节码，读取时不需要访问存储槽 (SLOAD)，极大地节省 Gas。
    address public immutable override factory;
    address public immutable override WETH;

    // 修饰符：交易截止时间检查
    // 作用：防止矿工恶意扣留交易（MEV 攻击）。如果交易被长时间挂起，价格可能已经变差，此时应直接失败。
    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'UniswapV2Router: EXPIRED');
        _;
    }

    constructor(address _factory, address _WETH) public {
        factory = _factory;
        WETH = _WETH;
    }

    // 接收 ETH 的函数
    // 逻辑：仅接受来自 WETH 合约的转账（即 WETH 解包成 ETH 时）。
    // 安全：防止用户手滑直接把 ETH 转给 Router 合约，因为 Router 没有提款函数，转进来就永久丢失了。
    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    // **** 添加流动性 (ADD LIQUIDITY) ****
    
    // [内部函数] 计算添加流动性的“最优比例”
    // 为什么需要它？因为 Pair 里的 x*y=k 模型决定了价格是储备量的比率。
    // 如果用户不按当前比例存入，就会发生套利损失。Router 帮用户计算出最完美的存入数量。
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired, // 用户想要存入的 A 数量
        uint amountBDesired, // 用户想要存入的 B 数量
        uint amountAMin,     // 用户能接受的最小 A（滑点保护）
        uint amountBMin      // 用户能接受的最小 B
    ) internal virtual returns (uint amountA, uint amountB) {
        // 1. 如果池子还不存在，Router 顺手帮忙创建了，优化用户体验
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        
        // 2. 获取当前池子的储备量 (Reserve)
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);
        
        // 3. 分支一：这是一个新池子 (Reserve 为 0)
        if (reserveA == 0 && reserveB == 0) {
            // 新池子没有价格，用户存多少就是多少，这决定了初始价格
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            // 4. 分支二：这是一个老池子
            // 计算最优的 B 数量：如果我存 Desired A，按当前比例需要配多少 B？
            uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
            
            // 如果算出来的 B <= 用户愿意给的最大值 Desired B
            if (amountBOptimal <= amountBDesired) {
                // 还要检查 B 是否满足最小值限制（防止存入瞬间价格剧烈波动）
                require(amountBOptimal >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                // 如果 B 不够用，那就反过来算 A：如果我存 Desired B，需要配多少 A？
                uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
                // 这里的 A 一定 <= Desired A，所以用 assert
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    // [外部接口] 两个 ERC20 代币添加流动性
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to, // LP Token 发给谁
        uint deadline
    ) external virtual override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        // 1. 调用上面的内部函数，算出真正应该存入多少钱
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        
        // 2. 计算 Pair 合约地址（使用 create2 预测，无需链上查询）
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        
        // 3. 将代币从用户钱包【直接】转给 Pair 合约
        // 注意：资金不经过 Router 中转，这不仅省 Gas，也避免了 Router 需要处理代币余额的复杂性
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        
        // 4. 调用 Pair 的 mint 函数，给 to 地址铸造 LP Token
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    // [外部接口] ETH + ERC20 添加流动性
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external virtual override payable ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
        // 1. 计算最优比例（把 ETH 当作 WETH 处理）
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value, // 用户发送的 ETH 数量作为 BDesired
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
        // 用户可能发了 1 ETH，但最优比例只需要 0.8 ETH，剩下 0.2 必须退回给用户
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // **** 移除流动性 (REMOVE LIQUIDITY) ****

    // [外部接口] 移除 ERC20-ERC20 流动性
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity, // 要销毁的 LP Token 数量
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountA, uint amountB) {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        
        // 1. 把 LP Token 从用户转给 Pair
        // 前提：用户必须先 Approve Router。Router 调用 transferFrom 把 LP 拿走发给 Pair
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        
        // 2. 销毁 LP，取出底层资产
        // amount0/1 是按 Pair 内代币地址排序返回的
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
        
        // 3. 排序匹配：因为 Pair 返回的是 token0/token1，我们需要映射回 tokenA/tokenB
        (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        
        // 4. 滑点检查：取出的币不能少于用户预期
        require(amountA >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
    }

    // [外部接口] 移除 ETH-ERC20 流动性
    // 逻辑：先用上面的 removeLiquidity 把 WETH 取出来，再解包成 ETH 给用户
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountToken, uint amountETH) {
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this), // 注意：to 是 Router 自己，因为 Router 需要先收到 WETH 才能解包
            deadline
        );
        
        // 把 ERC20 转给用户
        TransferHelper.safeTransfer(token, to, amountToken);
        
        // Router 把 WETH 换成 ETH
        IWETH(WETH).withdraw(amountETH);
        
        // Router 把 ETH 转给用户
        TransferHelper.safeTransferETH(to, amountETH);
    }

    // [外部接口] 带签名的移除流动性 (Permit)
    // 优势：用户不需要先发 Approve 交易（省 Gas），而是签名一个消息，Router 帮用户提交签名
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s // 签名参数
    ) external virtual override returns (uint amountA, uint amountB) {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        // 如果 approveMax 为真，则授权最大值 (2^256-1)，否则只授权 liquidity 数量
        uint value = approveMax ? uint(-1) : liquidity;
        
        // 1. 提交签名，让 Pair 批准 Router 动用用户的 LP Token
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        
        // 2. 执行移除逻辑
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    // [外部接口] 带签名的 ETH 版本移除流动性
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountToken, uint amountETH) {
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        uint value = approveMax ? uint(-1) : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // **** 移除流动性 (支持通缩代币) ****
    
    // [特殊接口] 为什么要支持通缩代币？
    // 如果 LP Token 本身有转账税，或者取出的 Token 有转账税，标准的 removeLiquidity 可能会因为金额检查失败而回滚。
    // 这个函数稍微放宽了逻辑，确保即使用户收到的钱变少了，交易也能成功。
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountETH) {
        (, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        // 直接把 Router 当前持有的所有 Token 转给用户（不管税后剩多少）
        TransferHelper.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }
    
    // Permit 版本的支持通缩代币移除
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountETH) {
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        uint value = approveMax ? uint(-1) : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            token, liquidity, amountTokenMin, amountETHMin, to, deadline
        );
    }

    // **** 交易 (SWAP) ****

    // [内部函数] 执行多跳路径交易 (A -> B -> C)
    // 前提：初始金额已经转入了第一个 Pair
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            // 获取当前这一跳的输入和输出代币地址
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            uint amountOut = amounts[i + 1]; // 下一跳应该收到的钱（预计算好的）
            
            // 确定调用 Pair.swap 时，哪一个是 0，哪一个是 amountOut
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            
            // 核心路由逻辑：
            // 如果还没到终点，接收者 (to) 就是下一个 Pair 的地址
            // 如果到了终点，接收者就是用户指定的 _to
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            
            // 执行 Swap。data 为空表示不使用闪电贷回调
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output)).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );
        }
    }

    // [外部接口] 场景：用确定的输入，换取尽可能多的输出 (Exact Input)
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        // 1. 预计算：根据输入金额，算出路径上每一步能换多少钱
        // 这里假设没有税，可以精准计算
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

    // [外部接口] 场景：用尽可能少的输入，换取确定的输出 (Exact Output)
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
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

    // [外部接口] ETH -> Token (Exact Input)
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH'); // 起点必须是 WETH
        amounts = UniswapV2Library.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        
        // 把用户的 ETH 包成 WETH
        IWETH(WETH).deposit{value: amounts[0]}();
        // 把 WETH 转给第一个 Pair
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        
        _swap(amounts, path, to);
    }

    // [外部接口] Token -> ETH (Exact Output)
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH'); // 终点必须是 WETH
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        
        // 接收者是 Router 自己 (address(this))，因为 Router 需要先把 WETH 收回来解包
        _swap(amounts, path, address(this));
        
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    // [外部接口] Token -> ETH (Exact Input)
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        virtual
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

    // [外部接口] ETH -> Token (Exact Output)
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        virtual
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

    // **** SWAP (支持通缩代币/转账收税代币) ****
    // 这是 Router02 相比 Router01 最大的升级点！

    // [内部函数] 支持通缩代币的 Swap 逻辑
    // 原理：不信任 amount 参数，只信任“余额变化”。
    // 每次 swap 前，检查 balance - reserve，这才是 Pair 真正收到的钱。
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output));
            uint amountInput;
            uint amountOutput;
            
            // 作用域块：避免 Stack Too Deep 错误
            { 
            (uint reserve0, uint reserve1,) = pair.getReserves();
            (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            
            // 核心逻辑：
            // 实际输入金额 = Pair当前余额 - Pair记录的储备量
            // 如果转账过程中扣了 10% 的税，这里算出来的就是税后的 90%
            amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
            
            // 根据实际到账的钱，计算能换多少输出
            amountOutput = UniswapV2Library.getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    // [外部接口] Token -> Token (支持通缩)
    // 注意：不支持 swapTokensForExactTokens，因为税率未知，无法反推精确输入
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) {
        // 1. 转账给第一个 Pair
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
        );
        
        // 2. 记录接收者当前的余额 (快照)
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        
        // 3. 执行特殊的 Swap
        _swapSupportingFeeOnTransferTokens(path, to);
        
        // 4. 检查：接收者余额增量 >= 最小值
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    // [外部接口] ETH -> Token (支持通缩)
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        payable
        ensure(deadline)
    {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        uint amountIn = msg.value;
        IWETH(WETH).deposit{value: amountIn}();
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn));
        
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    // [外部接口] Token -> ETH (支持通缩)
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        ensure(deadline)
    {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
        );
        _swapSupportingFeeOnTransferTokens(path, address(this));
        
        uint amountOut = IERC20(WETH).balanceOf(address(this));
        require(amountOut >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        
        IWETH(WETH).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
    }

    // **** 库函数包装 (LIBRARY FUNCTIONS) ****
    // 这些函数是为了方便前端直接调用 Router 查询价格，不需要单独引用 Library 合约
    
    function quote(uint amountA, uint reserveA, uint reserveB) public pure virtual override returns (uint amountB) {
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountOut)
    {
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountIn)
    {
        return UniswapV2Library.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(uint amountIn, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint amountOut, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }
}
