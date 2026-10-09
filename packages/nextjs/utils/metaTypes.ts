/** The typed-data field definitions shared by wallet signing and relayer parsing. */
export const TYPES = {
  BorrowAndDisburse: [
    { name: "borrower", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "to", type: "address" },
    { name: "repaymentPeriod", type: "uint256" },
    { name: "maxAprBps", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  RequestWithdrawal: [
    { name: "lender", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "to", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  BackRequest: [
    { name: "backer", type: "address" },
    { name: "borrower", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  Permit: [
    { name: "owner", type: "address" },
    { name: "spender", type: "address" },
    { name: "value", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;
