import { expect } from "chai";
import { ethers } from "hardhat";
import { DecentralizedMicrocredit, MockUSDC } from "../typechain-types";

describe("DecentralizedMicrocredit", function () {
  let microcredit: DecentralizedMicrocredit;
  let mockUSDC: MockUSDC;
  let owner: any;
  let lender: any;
  let borrower: any;
  let oracle: any;

  beforeEach(async function () {
    // Get signers
    [owner, lender, borrower, oracle] = await ethers.getSigners();

    // Deploy MockUSDC
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();

    // Deploy DecentralizedMicrocredit
    const DecentralizedMicrocredit = await ethers.getContractFactory(
      "DecentralizedMicrocredit"
    );
    microcredit = await DecentralizedMicrocredit.deploy(
      433, // effrRate 4.33%
      500, // riskPremium 5.0%
      100 * 1e6, // maxLoanAmount 100 USDC
      await mockUSDC.getAddress(),
      oracle.address
    );
    await microcredit.waitForDeployment();
  });

  describe("Deployment", function () {
    it("Should set the right owner", async function () {
      expect(await microcredit.owner()).to.equal(owner.address);
    });

    it("Should set the correct USDC address", async function () {
      expect(await microcredit.usdcToken()).to.equal(
        await mockUSDC.getAddress()
      );
    });

    it("Should set the correct oracle", async function () {
      expect(await microcredit.oracle()).to.equal(oracle.address);
    });

    it("Should set the correct parameters", async function () {
      expect(await microcredit.effrRate()).to.equal(433);
      expect(await microcredit.riskPremium()).to.equal(500);
      expect(await microcredit.maxLoanAmount()).to.equal(100 * 1e6);
    });
  });

  describe("Access Control", function () {
    it("Should allow owner to set base personalization", async function () {
      await expect(microcredit.setBasePersonalization(100)).to.not.be.reverted;
      expect(await microcredit.basePersonalization()).to.equal(100);
    });

    it("Should not allow non-owner to set base personalization", async function () {
      await expect(
        microcredit.connect(lender).setBasePersonalization(100)
      ).to.be.revertedWithCustomError(
        microcredit,
        "OwnableUnauthorizedAccount"
      );
    });
  });

  describe("USDC Operations", function () {
    it("Should allow minting USDC", async function () {
      const amount = ethers.parseUnits("1000", 6); // 1000 USDC
      await mockUSDC.mint(lender.address, amount);
      expect(await mockUSDC.balanceOf(lender.address)).to.equal(amount);
    });

    it("Should allow transferring USDC", async function () {
      const amount = ethers.parseUnits("100", 6); // 100 USDC
      await mockUSDC.mint(lender.address, amount);
      await mockUSDC.connect(lender).transfer(borrower.address, amount);
      expect(await mockUSDC.balanceOf(borrower.address)).to.equal(amount);
    });
  });

  describe("Loan Operations", function () {
    beforeEach(async function () {
      // Fund lender with USDC
      const lenderAmount = ethers.parseUnits("1000", 6);
      await mockUSDC.mint(lender.address, lenderAmount);

      // Fund borrower with ETH for gas
      const ethAmount = ethers.parseEther("10");
      await ethers.provider.send("hardhat_setBalance", [
        borrower.address,
        ethers.toBeHex(ethAmount),
      ]);
    });

    it("Should allow creating a loan request", async function () {
      const loanAmount = ethers.parseUnits("50", 6); // 50 USDC
      const duration = 30 * 24 * 60 * 60; // 30 days

      await expect(
        microcredit.connect(borrower).createLoanRequest(loanAmount, duration)
      ).to.not.be.reverted;
    });

    it("Should not allow loan amount exceeding max", async function () {
      const loanAmount = ethers.parseUnits("200", 6); // 200 USDC (exceeds max of 100)
      const duration = 30 * 24 * 60 * 60; // 30 days

      await expect(
        microcredit.connect(borrower).createLoanRequest(loanAmount, duration)
      ).to.be.reverted;
    });
  });

  describe("Oracle Operations", function () {
    it("Should allow oracle to update credit score", async function () {
      const creditScore = 750;
      await expect(
        microcredit
          .connect(oracle)
          .updateCreditScore(borrower.address, creditScore)
      ).to.not.be.reverted;

      expect(await microcredit.getCreditScore(borrower.address)).to.equal(
        creditScore
      );
    });

    it("Should not allow non-oracle to update credit score", async function () {
      const creditScore = 750;
      await expect(
        microcredit
          .connect(lender)
          .updateCreditScore(borrower.address, creditScore)
      ).to.be.revertedWithCustomError(microcredit, "UnauthorizedOracle");
    });
  });
});
