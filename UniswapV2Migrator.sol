pragma solidity =0.6.6;

// 引入辅助库，用于安全地发送 ETH 和 Token
import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

// 引入接口
import './interfaces/IUniswapV2Migrator.sol';
import './interfaces/V1/IUniswapV1Factory.sol';
import './interfaces/V1/IUniswapV1Exchange.sol';
import './interfaces/IUniswapV2Router01.sol';
import './interfaces/IERC20.sol';

contract UniswapV2Migrator is IUniswapV2Migrator {
    // 状态变量
    // immutable (不可变)：Solidity 0.6+ 新特性。
    // 类似于 constant，但在构造函数中赋值。部署后无法修改，且读取时极其省 Gas（直接作为常量嵌入字节码）。
    IUniswapV1Factory immutable factoryV1;
    IUniswapV2Router01 immutable router;

    constructor(address _factoryV1, address _router) public {
        factoryV1 = IUniswapV1Factory(_factoryV1);
        router = IUniswapV2Router01(_router);
    }

    // --- 接收 ETH 函数 ---
    // receive() 是 Solidity 0.6+ 新增的专门用于接收 ETH 的函数（替代了以前的 fallback）。
    // 为什么要收钱？因为从 V1 移除流动性时，V1 会把 ETH 发送给 msg.sender（也就是这个合约）。
    // 所以这个合约必须能接收 ETH，否则 V1 的 removeLiquidity 会失败。
    receive() external payable {}

    // --- 核心迁移函数 ---
    function migrate(address token, uint amountTokenMin, uint amountETHMin, address to, uint deadline)
        external
        override
    {
        // 1. 获取 V1 的交易所地址 (V1 是每个 Token 一个单独的 Exchange 合约)
        IUniswapV1Exchange exchangeV1 = IUniswapV1Exchange(factoryV1.getExchange(token));
        
        // 2. 查询用户在 V1 里的流动性余额 (LP Token)
        // 注意：这里默认迁移用户所有的 V1 流动性。如果只想迁移一部分，代码逻辑需要修改。
        uint liquidityV1 = exchangeV1.balanceOf(msg.sender);
        
        // 3. 把用户的 V1 LP Token 拉取到当前合约 (Migrator)
        // 前提：用户必须先在前端 Approve 这个 Migrator 合约。
        require(exchangeV1.transferFrom(msg.sender, address(this), liquidityV1), 'TRANSFER_FROM_FAILED');
        
        // 4. 从 V1 移除流动性
        // 调用 V1 的 removeLiquidity。
        // min_eth 和 min_tokens 设为 1，因为只要能取出任意数量即可（主要目的是搬家，不是交易）。
        // deadline 设为 -1 (无穷大)。
        // 结果：Migrator 合约现在持有了底层的 Token 和 ETH。
        (uint amountETHV1, uint amountTokenV1) = exchangeV1.removeLiquidity(liquidityV1, 1, 1, uint(-1));
        
        // 5. 授权 V2 Router
        // 因为下一步要调用 Router 添加流动性，所以要先批准 Router 动用刚才取出来的 Token。
        TransferHelper.safeApprove(token, address(router), amountTokenV1);
        
        // 6. 向 V2 添加流动性
        // 调用 Router 的 addLiquidityETH。
        // {value: amountETHV1} 是 Solidity 调用函数时附带 ETH 的语法。
        (uint amountTokenV2, uint amountETHV2,) = router.addLiquidityETH{value: amountETHV1}(
            token,
            amountTokenV1, // 把从 V1 取出的所有 Token 都放进去
            amountTokenMin,
            amountETHMin,
            to,            // V2 的 LP Token 发给谁（通常是用户自己）
            deadline
        );

        // 7. 处理“灰尘” (Dust Refund)
        // 如果 V1 的 ETH/Token 比例和 V2 当前的比例不完全一致，会有多余的钱剩在 Migrator 合约里。
        // 必须把这些剩下的钱退还给用户，否则就永远锁死在这里了。
        
        if (amountTokenV1 > amountTokenV2) {
            // 如果剩下了 Token
            TransferHelper.safeApprove(token, address(router), 0); //好习惯：重置授权为 0
            TransferHelper.safeTransfer(token, msg.sender, amountTokenV1 - amountTokenV2); // 退款
        } else if (amountETHV1 > amountETHV2) {
            // 如果剩下了 ETH
            // 注意：router.addLiquidityETH 保证了只会少用，不会多用，所以这里 else 是安全的
            TransferHelper.safeTransferETH(msg.sender, amountETHV1 - amountETHV2); // 退款
        }
    }
}
