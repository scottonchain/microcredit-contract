"use client";

import type { NextPage } from "next";
import { AttestationUI } from "~~/components/attestation/AttestationUI";

const Attestations: NextPage = () => {
  return (
    <div className="flex items-center flex-col flex-grow pt-10">
      <div className="px-5">
        <h1 className="text-center mb-8">
          <span className="block text-4xl font-bold">Attestations</span>
          <span className="block text-2xl mb-2">Create and view attestations between addresses</span>
        </h1>
        <AttestationUI />
      </div>
    </div>
  );
};

export default Attestations; 