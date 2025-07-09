"use client";

import Link from "next/link";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { 
  UserGroupIcon, 
  CurrencyDollarIcon, 
  ChartBarIcon, 
  HandThumbUpIcon,
  CreditCardIcon,
  BanknotesIcon,
  UserIcon,
  CogIcon
} from "@heroicons/react/24/outline";
import { Address } from "~~/components/scaffold-eth";
import WalletSwitcher from "~~/components/WalletSwitcher";

const Home: NextPage = () => {
  const { address: connectedAddress } = useAccount();

  const features = [
    {
      title: "Make Attestation",
      description: "Attest to someone's creditworthiness",
      icon: HandThumbUpIcon,
      href: "/attest",
      color: "bg-blue-500",
    },
    {
      title: "Request Loan",
      description: "Borrow funds based on your credit score",
      icon: CreditCardIcon,
      href: "/borrow",
      color: "bg-green-500",
    },
    {
      title: "Lend Funds",
      description: "Fund loans and earn interest",
      icon: BanknotesIcon,
      href: "/lend",
      color: "bg-purple-500",
    },
    {
      title: "Repay Loan",
      description: "Repay your outstanding loans",
      icon: CurrencyDollarIcon,
      href: "/repay",
      color: "bg-orange-500",
    },
    {
      title: "Credit Scores",
      description: "View credit scores and reputation",
      icon: ChartBarIcon,
      href: "/scores",
      color: "bg-red-500",
    },
    {
      title: "Admin Panel",
      description: "Oracle functions and system management",
      icon: CogIcon,
      href: "/admin",
      color: "bg-gray-500",
    },
  ];

  return (
    <>
      <div className="flex items-center flex-col grow pt-10">
        <div className="px-5 w-full max-w-7xl">
          <h1 className="text-center">
            <span className="block text-2xl mb-2">Welcome to</span>
            <span className="block text-4xl font-bold">Decentralized Microcredit</span>
          </h1>
          <p className="text-center text-lg mt-4 mb-4">
            A social reputation-based lending platform powered by PageRank
          </p>

          {/* Wallet connect / switcher */}
          <WalletSwitcher />

          {connectedAddress && (
            <div className="bg-base-100 rounded-lg p-6 mb-8 shadow-lg">
              <h2 className="text-xl font-semibold mb-4">Your Profile</h2>
              <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div className="flex items-center space-x-2">
                  <UserIcon className="h-5 w-5" />
                  <span className="font-medium">Address:</span>
                  <Address address={connectedAddress} />
                </div>
                <div className="flex items-center space-x-2">
                  <ChartBarIcon className="h-5 w-5" />
                  <span className="font-medium">Credit Score:</span>
                  <span className="text-lg font-bold text-green-500">
                    75.50%
                  </span>
                </div>
                <div className="flex items-center space-x-2">
                  <BanknotesIcon className="h-5 w-5" />
                  <span className="font-medium">Status:</span>
                  <span className="text-lg font-bold text-blue-500">
                    Eligible for loans
                  </span>
                </div>
              </div>
            </div>
          )}

          {/* Pool Statistics */}
          <div className="bg-base-100 rounded-lg p-6 mb-8 shadow-lg">
            <h2 className="text-xl font-semibold mb-4">Lending Pool Statistics</h2>
            <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
              <div className="text-center">
                <div className="text-2xl font-bold text-green-500">
                  $50,000.00
                </div>
                <div className="text-sm text-gray-600">Total Deposits</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-blue-500">
                  $35,000.00
                </div>
                <div className="text-sm text-gray-600">Available Funds</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-purple-500">
                  $2,500.00
                </div>
                <div className="text-sm text-gray-600">Total Earned</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-orange-500">
                  15
                </div>
                <div className="text-sm text-gray-600">Active Lenders</div>
              </div>
            </div>
          </div>

          {/* Feature Cards */}
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
            {features.map((feature, index) => (
              <Link key={index} href={feature.href} className="group">
                <div className="bg-base-100 p-6 rounded-lg shadow-lg hover:shadow-xl transition-all duration-200 group-hover:scale-105">
                  <div className={`inline-flex p-3 rounded-lg ${feature.color} text-white mb-4`}>
                    <feature.icon className="h-6 w-6" />
                  </div>
                  <h3 className="text-lg font-semibold mb-2">{feature.title}</h3>
                  <p className="text-gray-600">{feature.description}</p>
                </div>
              </Link>
            ))}
          </div>

          {/* How it works section */}
          <div className="mt-16 bg-base-300 rounded-lg p-8">
            <h2 className="text-2xl font-bold text-center mb-8">How It Works</h2>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
              <div className="text-center">
                <div className="bg-blue-100 w-16 h-16 rounded-full flex items-center justify-center mx-auto mb-4">
                  <UserGroupIcon className="h-8 w-8 text-blue-600" />
                </div>
                <h3 className="text-lg font-semibold mb-2">1. Build Reputation</h3>
                <p className="text-gray-600">
                  Get attested by others in your community to build your credit score
                </p>
              </div>
              <div className="text-center">
                <div className="bg-green-100 w-16 h-16 rounded-full flex items-center justify-center mx-auto mb-4">
                  <CreditCardIcon className="h-8 w-8 text-green-600" />
                </div>
                <h3 className="text-lg font-semibold mb-2">2. Request Loan</h3>
                <p className="text-gray-600">
                  Submit loan requests based on your PageRank-based credit score
                </p>
              </div>
              <div className="text-center">
                <div className="bg-purple-100 w-16 h-16 rounded-full flex items-center justify-center mx-auto mb-4">
                  <BanknotesIcon className="h-8 w-8 text-purple-600" />
                </div>
                <h3 className="text-lg font-semibold mb-2">3. Earn Interest</h3>
                <p className="text-gray-600">
                  Lend funds to borrowers and earn interest on your deposits
                </p>
              </div>
            </div>
          </div>

          {/* Key Features */}
          <div className="mt-16">
            <h2 className="text-2xl font-bold text-center mb-8">Key Features</h2>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
              <div className="bg-base-100 p-6 rounded-lg shadow-lg">
                <h3 className="text-lg font-semibold mb-3 flex items-center">
                  <ChartBarIcon className="h-6 w-6 mr-2 text-blue-500" />
                  PageRank Credit Scoring
                </h3>
                <p className="text-gray-600">
                  Uses Google&apos;s PageRank algorithm to calculate credit scores based on social attestations and network relationships.
                </p>
              </div>
              <div className="bg-base-100 p-6 rounded-lg shadow-lg">
                <h3 className="text-lg font-semibold mb-3 flex items-center">
                  <UserGroupIcon className="h-6 w-6 mr-2 text-green-500" />
                  Social Attestations
                </h3>
                <p className="text-gray-600">
                  Community members can attest to each other&apos;s creditworthiness with confidence levels.
                </p>
              </div>
              <div className="bg-base-100 p-6 rounded-lg shadow-lg">
                <h3 className="text-lg font-semibold mb-3 flex items-center">
                  <BanknotesIcon className="h-6 w-6 mr-2 text-purple-500" />
                  Decentralized Lending
                </h3>
                <p className="text-gray-600">
                  Peer-to-peer lending with automatic fund allocation and interest distribution.
                </p>
              </div>
              <div className="bg-base-100 p-6 rounded-lg shadow-lg">
                <h3 className="text-lg font-semibold mb-3 flex items-center">
                  <CogIcon className="h-6 w-6 mr-2 text-orange-500" />
                  Oracle Management
                </h3>
                <p className="text-gray-600">
                  Admin panel for managing oracles, fee rates, and system parameters.
                </p>
              </div>
            </div>
          </div>

          {/* Call to Action */}
          <div className="mt-16 text-center">
            <h2 className="text-2xl font-bold mb-4">Ready to Get Started?</h2>
            <p className="text-gray-600 mb-6">
              Connect your wallet and start building your credit reputation today.
            </p>
            <div className="flex justify-center space-x-4">
              <Link href="/attest" className="bg-blue-500 hover:bg-blue-600 text-white font-bold py-3 px-6 rounded-lg transition-colors">
                Make Attestation
              </Link>
              <Link href="/borrow" className="bg-green-500 hover:bg-green-600 text-white font-bold py-3 px-6 rounded-lg transition-colors">
                Request Loan
              </Link>
            </div>
          </div>
        </div>
      </div>
    </>
  );
};

export default Home;
