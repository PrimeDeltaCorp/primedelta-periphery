# DCLEX protocol periphery contracts

## Getting Started
You can install dclex-periphery in your project using forge:
```
forge install dclex-platform/dclex-periphery
```

The main contract of intereset in this repository is DclexRouter. It allows to straightforwardly swap DCLEX stock tokens. Tokens might be swapped using stocks, USDC or ether as input or output in both "exact input" and "exact output" variants:  
```solidity
// Buy 1 AAPL stock token using USDC, paying at maximum 1000 USDC
dclexRouter.buyExactOutput(
    address(aaplStock),
    1 ether,
    1000e6,
    DEADLINE,
    PYTH_DATA
);

// Sell 5 NVDA stock tokens and receive USDC (1200 USDC at minimum)
dclexRouter.sellExactInput(
    address(nvdaStock),
    5 ether,
    1200e6,
    DEADLINE,
    PYTH_DATA
);

// Execute a ETH -> AAPL exact input swap (no minimum output)
dclexRouter.swapExactInput{value: 1 ether}(
    address(0),
    address(aaplStock),
    0.01 ether,
    0,
    DEADLINE,
    PYTH_DATA
);

// Execute a NVDA -> AAPL exact output swap (no maximum input)
dclexRouter.swapExactInput{value: 1 ether}(
    address(0),
    address(aaplStock),
    0.01 ether,
    type(uint256).max,
    DEADLINE,
    PYTH_DATA
);
```

## Test
You can run the full test suite using forge:
```
forge test
```

## License
DCLEX periphery is licensed under the Business Source License 1.1 (`BUSL-1.1`)
