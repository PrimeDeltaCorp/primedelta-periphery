// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {
    DigitalIdentity
} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRouter {
    function stockTokenToPool(address token) external view returns (address);
}

/// @notice Re-deploys DclexRouter cleanly with exactly 44 canonical stock tokens
///         sourced from the backend DB (no duplicates).
///         Must be run with FOUNDRY_PROFILE=router-deploy.
contract RedeployRouter is Script {
    address constant CURRENT_ROUTER =
        0xfF545934344DbD71DdD177428E5FE9342D57A879;
    address constant DUSD = 0x951c4871D16d953a3Fd64c17a756B1aA95D63E58;
    address constant FACTORY = 0x5d360D437c9bEd63B149435b11f5c5c5d41bb549;
    address constant ADMIN = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    // 44 canonical stock token addresses from backend DB (ordered by symbol)
    function getCanonicalTokens() internal pure returns (address[] memory) {
        address[] memory tokens = new address[](44);
        tokens[0] = 0x791Dc101D61d8f773252489FdCFa960F5bD1e722; // AAPL
        tokens[1] = 0x7F2D966938e4d55b70A6A6476F47af01CE0E5879; // AI
        tokens[2] = 0xf5Ef8b639772FBeb0f4aBa4Ed1BFc1Ce8d1Fa4E4; // AMC
        tokens[3] = 0xC0d27Eac3f73b5c0fD3d237669372C08569a219A; // AMGN
        tokens[4] = 0xEB9ffe41e53942584C72A1831B27BDea8D7B5b20; // AMZN
        tokens[5] = 0x77aec2f1aa4eeD376ecc947eb77767eF37758760; // AXP
        tokens[6] = 0xc07b05f26C4289359e0f3f2343823673F73A0614; // BA
        tokens[7] = 0x96E211529956222d69dFb54b62A3CA7BF8642B04; // BLK
        tokens[8] = 0x19c671Cd8e013f6c25F89852Ba266f798A6e1610; // CAT
        tokens[9] = 0xBbb3928950d142Bf13e7fe5Ad5d8fC8B3831ad67; // COIN
        tokens[10] = 0xFD0FA98130Be5D0591b1E47b19d61276231F04e4; // CPNG
        tokens[11] = 0xeA93a7d0302b8EE14bcAe9D25B4d320f95039141; // CRM
        tokens[12] = 0x6F2C10bcf06d91b52E11D496D74F708d29743BE4; // CSCO
        tokens[13] = 0xd7c5750FbC1e515BFc410E6Bd1d3e803DAa6df21; // CVX
        tokens[14] = 0x4B5DFa10ECbcaBfa9E19a516fbC7Ce7B7b93EcF7; // DIS
        tokens[15] = 0xe3673743baDa42B0a714aAdC90bC91e45ab8a47D; // DOW
        tokens[16] = 0xf82BEb58aFa5cB1979CCe207E0489D0Cf99DB88C; // GE
        tokens[17] = 0xA17c25746F5A857512c372e5F4d4086d017EC797; // GME
        tokens[18] = 0xA473BB5F25d5d26710AE149bACBE2A214E2225fB; // GOOG
        tokens[19] = 0xdfD218057CFf851dad65a1A412D1c5EbF0ECC0DE; // GS
        tokens[20] = 0xbd3912910ffb11795b43cE09A88bB1Ae8b208b00; // HD
        tokens[21] = 0x70FA2c3Bb4b0a3F164C955Ea758Aa6d4bb958E32; // HON
        tokens[22] = 0x8c4a8361a00900D6A74D0Cc7FC106aEA9A6568f1; // IBM
        tokens[23] = 0xaaF37745c712A218D23Ffa91ba075C4E33529a62; // INTC
        tokens[24] = 0x2Fce342f5Db2b6A35c6cD03ED99BaE78A56F02F1; // JNJ
        tokens[25] = 0x177d600f1D4FaA9BE36D6c72F181fbA66635c7E0; // JPM
        tokens[26] = 0xd917a3287883a47929BA46e7DaE5d4d58a996210; // KO
        tokens[27] = 0x5D392f871c86020787191803D6A2509Dca4658b7; // MCD
        tokens[28] = 0xcAe3b672E3e5Bcc1DF406BD3782CcF148BF8738F; // META
        tokens[29] = 0xB5b4dfF8E20B6DE4655Ecbe364bdcC1c10C7e5d4; // MMM
        tokens[30] = 0x630A6b82136b8dE82d84B375560f834D620BDab6; // MRK
        tokens[31] = 0x4394Ddf4B129b5DC37eF8EB33eb96CbF729ec73C; // MSFT
        tokens[32] = 0xFd28B31DEf07e3c4060734a45243404Ccf48ba32; // MSTR
        tokens[33] = 0x09FBe2F04afaB6F8945F465b4a2D5Ff488dB324c; // NFLX
        tokens[34] = 0x34134d2ad7F9F5bc00214ECB6D473e6c4a9fE6D5; // NKE
        tokens[35] = 0x705a25Cc5ef5872654597bF8C8189E1897Ef896d; // NVDA
        tokens[36] = 0xEDf5a153AE59dAdacF4153bE1da5A696eAFa5De1; // PG
        tokens[37] = 0x78CB002e37330B85539dAC7E40f3247CE3F24C91; // TSLA
        tokens[38] = 0x8F4D820ba6f974414618b89d5cB566AAA9eCA5B0; // TRV
        tokens[39] = 0x30D6e93663cfD9F022AB46c7Fa8163aF161819Cf; // UNH
        tokens[40] = 0x78F3B69Dc41de3C73ae4444ae20920C606187f78; // V
        tokens[41] = 0x2415BAcB2aaB33a8f702d03638d422A922a4A3B7; // VZ
        tokens[42] = 0x1236eC8F3646AC0b957725df4144988a3785A547; // WBA
        tokens[43] = 0xb9f17a3Cb0504B6D9d9491777ef418C464C5DD83; // WMT
        return tokens;
    }

    function run() external {
        runInternal();
    }

    function runInternal() public {
        IRouter currentRouter = IRouter(CURRENT_ROUTER);
        address[] memory tokens = getCanonicalTokens();

        vm.startBroadcast();

        DclexRouter newRouter = new DclexRouter(IERC20(DUSD));
        console.log("New DclexRouter deployed at:", address(newRouter));

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            address pool = currentRouter.stockTokenToPool(token);
            require(pool != address(0), "Pool not found for token");
            newRouter.addPool(token, DclexRouter.PoolType.DCLEX, pool, 0);
        }
        console.log("Registered", tokens.length, "pools");

        newRouter.transferOwnership(ADMIN);
        console.log("Ownership transferred to:", ADMIN);

        // Router needs a DID because it acts as intermediary for dUSD
        // in stock-to-stock swaps (receives from pool A, sends to pool B)
        DigitalIdentity digitalIdentity = DigitalIdentity(
            address(Factory(FACTORY).getDID())
        );
        digitalIdentity.mintAdmin(address(newRouter), 2, bytes32(0));
        console.log("DID minted for router");

        vm.stopBroadcast();
    }
}
