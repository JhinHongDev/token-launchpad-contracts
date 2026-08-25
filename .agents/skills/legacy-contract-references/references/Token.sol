// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;


import "./OpenZeppelinDependencies.sol";
import "./Interfaces.sol";

/**
 * @title StagedCustomToken
 * @dev 基于FEG SmartDeFi分阶段初始化模式的代币合约
 * 解决构造函数复杂性导致的部署失败问题
 */
contract StagedCustomToken is ERC20, Ownable {
    struct BasicAdvancedConfig {
        uint256 feeBuy;
        uint256 feeSell;

        //燃烧底池
        bool lpBurnEnabled;
        uint256 lpBurnFrequency;
        uint256 percentForLPBurn;
        uint256 burnLimit;
        //开盘后价格保护
        uint256 protectTime;
        uint256 protectFee;
        //是否根卖
        bool isInsideSell;
        uint256 swapThreshold;
    }

    BasicAdvancedConfig public baseConfig;

    bool public tradingEnabled = false;
    uint256 private tradingTime;
    bool private swapIng;

    mapping(address => bool) public _autoPair;
    mapping(address => bool) private excludeFeeList;
    address public feeRecipient;
        
    IPancakeRouter02 router = IPancakeRouter02(0xD99D1c33F9fC3444f8101754aBC46c52416550D1);
    address public pairTRX;

    uint256 public lastLpBurnTime;
    uint256 public percentDiv = 10000;

    address public presaleContract;  // 预售合约地址

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _totalSupply,
        address _factoryAddress,
        address _feeRecipient,
        BasicAdvancedConfig memory _config
    ) ERC20(_name, _symbol) Ownable() {
        // 将所有权转移给工厂地址
        _transferOwnership(_factoryAddress);

        feeRecipient = _feeRecipient;
        baseConfig = _config;

        excludeFeeList[address(this)] = true;
        // excludeFeeList[_owner] = true;
        excludeFeeList[_factoryAddress] = true;
        excludeFeeList[feeRecipient] = true;


        IPancakeFactory factory = IPancakeFactory(router.factory());
        pairTRX = factory.createPair(address(this), router.WETH());
        _autoPair[pairTRX] = true;

        _mint(_factoryAddress, _totalSupply);
    }

    function _transfer(address from, address to, uint256 amount) internal virtual override {        

        if(_autoPair[from] || _autoPair[to]) {
            address _user;
            uint256 _fee;

            //buy
            if(_autoPair[from]) {
                _user = to;
                _fee = baseConfig.feeBuy;
            }
            //sell
            else if(_autoPair[to]) {
                _user = from;
                _fee = baseConfig.feeSell;
            }

            if (!isExcludeFee(_user)) {
                require(tradingEnabled, "not Launch");      
            }

            if(baseConfig.protectTime != 0){
                if(tradingEnabled && block.timestamp <= tradingTime + baseConfig.protectTime){
                    _fee = baseConfig.protectFee;
                }
            }

            if (!isExcludeFee(from) && !isExcludeFee(to)) {
                uint256 fee = (amount * _fee) / percentDiv;
                if(baseConfig.isInsideSell){
                    super._transfer(from, address(this), fee);
                }else{
                    super._transfer(from, feeRecipient, fee);
                }

                if(_autoPair[to]){
                    autoBurnUniswapPair();
                    if(baseConfig.isInsideSell){
                        swapIng = true;
                        swapTokenForFee();
                        swapIng = false;
                    }
                }
            }
        }

        super._transfer(from, to, amount);
    }

    function autoBurnUniswapPair() internal {
        if(baseConfig.lpBurnEnabled) {
            if (block.timestamp - lastLpBurnTime > baseConfig.lpBurnFrequency && balanceOf(pairTRX) > baseConfig.burnLimit) {
                burnPair(pairTRX);
                lastLpBurnTime = block.timestamp;
            }
        }     
    }

    function burnPair(address _pair) internal {
        uint256 liquidityPairBalance = balanceOf(_pair);
        uint256 amountToBurn = (liquidityPairBalance * baseConfig.percentForLPBurn) /
            percentDiv;

        if (amountToBurn > 0) {
            super._transfer(_pair, address(0xdead), amountToBurn);
            IPancakePair(_pair).sync();
        }
    }

    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "Already enabled");
        tradingEnabled = true;
        tradingTime = block.timestamp;
    }

    function setExcludeFee(address[] calldata accounts, bool excluded) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            excludeFeeList[accounts[i]] = excluded;
        }
    }

    function isExcludeFee(address account) public view returns (bool) {
        return excludeFeeList[account];
    }

    function swapTokenForFee() private {
        uint256 balance = balanceOf(address(this));
        if (balance >= baseConfig.swapThreshold) {
            swapTokenToTRX(balance);
        }
    }

    function swapTokenToTRX(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            feeRecipient,
            block.timestamp
        );  
    }

    /**
     * @dev 预售合约调用的权限放弃函数
     * 只能由预售合约在流动性添加成功后调用
     */
    function renounceOwnershipByPresale() external {
        require(msg.sender == presaleContract, "Only presale contract can call");
        _transferOwnership(address(0));
    }

    /**
     * @dev 设置预售合约地址（只能由owner调用一次）
     */
    function setPresaleContract(address _presaleContract) external onlyOwner {
        require(_presaleContract != address(0), "Invalid presale contract");
        require(presaleContract == address(0), "Presale contract already set");
        presaleContract = _presaleContract;
    }

    receive() external payable {}
}
