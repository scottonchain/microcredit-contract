"use client";

import React, { useRef } from "react";
import Image from "next/image";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { hardhat } from "viem/chains";
import { 
  Bars3Icon, 
  BugAntIcon, 
  CreditCardIcon, 
  BanknotesIcon, 
  CogIcon,
  WrenchScrewdriverIcon
} from "@heroicons/react/24/outline";
import { FaucetButton, RainbowKitCustomConnectButton, USDCFaucetButton } from "~~/components/scaffold-eth";
// removed balance hooks
import { useOutsideClick, useTargetNetwork } from "~~/hooks/scaffold-eth";

type HeaderMenuLink = {
  label: string;
  href: string;
  icon?: React.ReactNode;
};

export const menuLinks: HeaderMenuLink[] = [
  {
    label: "Home",
    href: "/",
  },
  {
    label: "Borrower",
    href: "/borrower",
    icon: <CreditCardIcon className="h-4 w-4" />,
  },
  {
    label: "Lender",
    href: "/lender",
    icon: <BanknotesIcon className="h-4 w-4" />,
  },
  {
    label: "Admin",
    href: "/admin",
    icon: <CogIcon className="h-4 w-4" />,
  },
];

type HeaderMenuLinksProps = {
  links: HeaderMenuLink[];
};

export const HeaderMenuLinks = ({ links }: HeaderMenuLinksProps) => {
  const pathname = usePathname();

  return (
    <>
      {links.map(({ label, href, icon }) => {
        const isActive = pathname === href;
        return (
          <li key={href}>
            <Link
              href={href}
              passHref
              className={`${
                isActive ? "bg-secondary shadow-md" : ""
              } hover:bg-secondary hover:shadow-md focus:!bg-secondary active:!text-neutral py-1.5 px-3 text-sm rounded-full gap-2 grid grid-flow-col`}
            >
              {icon}
              <span>{label}</span>
            </Link>
          </li>
        );
      })}
    </>
  );
};

/**
 * Site header
 */
export const Header = () => {
  const { targetNetwork } = useTargetNetwork();
  const isLocalNetwork = targetNetwork.id === hardhat.id;

  const burgerMenuRef = useRef<HTMLDetailsElement>(null);
  useOutsideClick(burgerMenuRef, () => {
    burgerMenuRef?.current?.removeAttribute("open");
  });

  // Removed display-name handling

  return (
    <div className="sticky lg:static top-0 navbar bg-base-100 min-h-0 shrink-0 justify-between z-20 shadow-md shadow-secondary px-0 sm:px-2">
      <div className="navbar-start w-auto lg:w-1/2">
        <details className="dropdown" ref={burgerMenuRef}>
          <summary className="ml-1 btn btn-ghost hover:bg-transparent">
            <Bars3Icon className="h-1/2" />
          </summary>
          <ul
            className="menu menu-compact dropdown-content mt-3 p-2 shadow-sm bg-base-100 rounded-box w-52"
            onClick={() => {
              burgerMenuRef?.current?.removeAttribute("open");
            }}
          >
            <HeaderMenuLinks links={menuLinks} />
          </ul>
        </details>
        <Link href="/" passHref className="hidden lg:flex items-center gap-2 ml-4 mr-6 shrink-0">
          <div className="flex relative w-10 h-10">
            <Image alt="LoanLink logo" className="cursor-pointer" width={40} height={40} src="/logo.svg" />
          </div>
          <div className="flex flex-col">
            <span className="font-bold leading-tight">LoanLink</span>
            <span className="text-xs">Social lending platform</span>
          </div>
        </Link>
        {(() => {
          const advanced = ["Admin", "Oracle Setup"];
          const userLinks = menuLinks.filter(l => !advanced.includes(l.label));
          return (
            <ul className="hidden lg:flex lg:flex-nowrap menu menu-horizontal px-1 gap-2">
              <HeaderMenuLinks links={userLinks} />
            </ul>
          );
        })()}
      </div>
      <div className="navbar-end grow mr-4">
        <RainbowKitCustomConnectButton />
        {/* balance handled inside connect button now */}
        {/* Faucets hidden for production
        {isLocalNetwork && (<>
          <FaucetButton />
          <USDCFaucetButton />
        </>)}
        */}
      </div>
    </div>
  );
};