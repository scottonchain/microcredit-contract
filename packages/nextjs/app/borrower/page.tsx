"use client";

import type { NextPage } from "next";
import BorrowPage from "../borrow/page";
import RepayPage from "../repay/page";

const Borrower: NextPage = () => {
  return (
    <>
      {/* Borrow wizard / new loan */}
      <BorrowPage />
      {/* Active loan & repayment section */}
      <RepayPage />
    </>
  );
};

export default Borrower; 