# Solady (vendored)

`SafeTransferLib.sol` 与 `FixedPointMathLib.sol` 原样取自 flap.sh 生产合约
（BSC 0x0e7Effa4fb7C528BBc65296f9A7580b3a63Df9C5，Dividend）验证源码包中锁定的
solady 版本（MIT），即上游实际部署所用字节。

未以 git submodule 方式引入：需锁定与生产一致的版本而非最新 main。
如后续升级 solady，须重新核对 Dividend 相关函数行为等价。
