"use client";

import Image from "next/image";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { BanknotesIcon, CreditCardIcon } from "@heroicons/react/24/outline";
import { RainbowKitCustomConnectButton } from "~~/components/scaffold-eth";

const links = [
  { label: "Borrower", href: "/borrower", Icon: CreditCardIcon },
  { label: "Lender", href: "/lender", Icon: BanknotesIcon },
];

export const Header = () => {
  const pathname = usePathname();
  return (
    <div className="sticky lg:static top-0 navbar bg-base-100 min-h-0 shrink-0 justify-between z-20 shadow-md shadow-secondary px-0 sm:px-2">
      <div className="navbar-start w-auto lg:w-1/2">
        <Link href="/" className="hidden lg:flex items-center gap-2 ml-4 mr-6 shrink-0">
          <Image alt="LoanLink logo" width={40} height={40} src="/logo.svg" />
          <div className="flex flex-col">
            <span className="font-bold leading-tight">LoanLink</span>
            <span className="text-xs">Social lending platform</span>
          </div>
        </Link>
        <ul className="hidden lg:flex lg:flex-nowrap menu menu-horizontal px-1 gap-2">
          {links.map(({ label, href, Icon }) => (
            <li key={href}>
              <Link
                href={href}
                className={`${pathname === href ? "bg-secondary text-secondary-content shadow-md" : ""} hover:bg-secondary hover:text-secondary-content hover:shadow-md focus:!bg-secondary focus:!text-secondary-content active:!text-secondary-content py-1.5 px-3 text-sm rounded-full gap-2 grid grid-flow-col`}
              >
                <Icon className="h-4 w-4" />
                <span>{label}</span>
              </Link>
            </li>
          ))}
        </ul>
      </div>
      <div className="navbar-end grow mr-4">
        <RainbowKitCustomConnectButton />
      </div>
    </div>
  );
};
