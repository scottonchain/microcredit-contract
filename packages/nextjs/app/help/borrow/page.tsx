import type { NextPage } from "next";
import Link from "next/link";

const BorrowHelpPage: NextPage = () => {
  return (
    <div className="flex flex-col items-center pt-10 px-5 max-w-3xl mx-auto">
      <h1 className="text-3xl font-bold mb-6 text-center">Borrower Guide</h1>
      <p className="text-gray-700 mb-4">
        LoanLink lets you access small loans backed by your social reputation rather than traditional credit history. Here’s
        how to get started:
      </p>
      <ol className="list-decimal list-inside space-y-3 text-gray-700">
        <li>
          <span className="font-medium">Create your attestation link.</span> On the Borrower page, copy your unique link (or QR code).
        </li>
        <li>
          <span className="font-medium">Share it with trusted peers.</span> Ask friends, family, or colleagues who know you to
          open the link and click “Attest.” Each attestation raises your credit score.
        </li>
        <li>
          <span className="font-medium">Watch your score.</span> Once your score is above 0%, the loan request form unlocks.
        </li>
        <li>
          <span className="font-medium">Request a loan.</span> Choose an amount and repayment period. The pool will match funds
          automatically.
        </li>
        <li>
          <span className="font-medium">Repay over time.</span> Make repayments before the due date to improve your reputation
          for future borrowing.
        </li>
      </ol>

      <p className="text-gray-700 mt-6">
        Need more help? Reach out on our&nbsp;
        <Link href="https://discord.gg" target="_blank" className="link">
          community Discord
        </Link>
        .
      </p>

      <Link href="/borrower" className="btn btn-primary mt-8">Back to Borrower Dashboard</Link>
    </div>
  );
};

export default BorrowHelpPage; 