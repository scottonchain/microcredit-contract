// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.30;

// import "forge-std/Script.sol";
// import "../contracts/DecentralizedMicrocredit.sol";
// import "../contracts/MockUSDC.sol";
// import "@openzeppelin/contracts/utils/Strings.sol";

// contract SeedBorrower is Script {
//     function run() external {
//         uint256 idx       = vm.envUint("BORROWER_INDEX");
//         address microAddr = vm.envAddress("MICRO_ADDRESS");
//         vm.startBroadcast();
//         DecentralizedMicrocredit(microAddr)
//             .registerBorrower(string.concat("Borrower-", Strings.toString(idx)));
//         vm.stopBroadcast();
//     }
// }

// contract SeedAttestation is Script {
//     function run() external {
//         uint256 bIdx      = vm.envUint("BORROWER_INDEX");
//         uint256 lIdx      = vm.envUint("LENDER_INDEX");
//         uint256 lenderPK  = vm.envUint("LENDER_PK");
//         address microAddr = vm.envAddress("MICRO_ADDRESS");
//         vm.startBroadcast(lenderPK);
//         DecentralizedMicrocredit(microAddr).attestBorrower(bIdx, lIdx);
//         vm.stopBroadcast();
//     }
// }

// contract SeedLoanRequest is Script {
//     function run() external {
//         uint256 idx       = vm.envUint("BORROWER_INDEX");
//         uint256 amount    = vm.envUint("LOAN_AMOUNT");
//         address microAddr = vm.envAddress("MICRO_ADDRESS");
//         address usdcAddr  = vm.envAddress("USDC_ADDRESS");
//         vm.startBroadcast();
//         MockUSDC(usdcAddr).approve(microAddr, amount);
//         DecentralizedMicrocredit(microAddr).requestLoan(idx, amount);
//         vm.stopBroadcast();
//     }
// }
