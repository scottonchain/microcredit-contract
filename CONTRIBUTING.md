# Welcome to Decentralized Microcredit Platform Contributing Guide

Thank you for investing your time in contributing to the Decentralized Microcredit Platform!

This guide aims to provide an overview of the contribution workflow to help us make the contribution process effective for everyone involved.

## About the Project

The Decentralized Microcredit Platform is a peer-to-peer micro-lending application on the Ethereum network that enables collateral-free loans backed by social reputation rather than traditional credit history.

Read the [README](README.md) to get an overview of the project.

### Vision

The goal of this project is to democratize access to credit through:
- **Credit that cannot be manufactured**: borrowers draw on credit they hold (a line issued by the owner or the credit oracle, interest they have paid, or stake) or credit that others back them with from their own. See [docs/CREDIT_MODEL.md](docs/CREDIT_MODEL.md)
- **Fixed-rate loans** based on real economic indicators (EFFR + risk premium)
- **Unified lending pool** with proportional yield distribution
- **Backers who stand behind borrowers**: on a default their stake is slashed and their committed credit is burned, and a first-loss reserve pays before lenders do

### Project Status

The project is under active development with a focus on:
- Smart contract optimization and security
- Frontend user experience improvements
- Oracle integration enhancements
- Testing and documentation

## Getting Started

You can contribute to this repo in many ways:

- Solve open issues
- Report bugs or feature requests
- Improve smart contract efficiency
- Enhance frontend user experience
- Improve documentation
- Add test coverage

Contributions are made via Issues and Pull Requests (PRs). A few general guidelines for contributions:

- Search for existing Issues and PRs before creating your own.
- Contributions should only fix/add the functionality in the issue OR address style issues, not both.
- If you're running into an error, please give context. Explain what you're trying to do and how to reproduce the error.
- Please use the same formatting in the code repository. You can configure your IDE to do it by using the prettier / linting config files included in each package.
- If applicable, please edit the README.md file to reflect the changes.

## Development Setup

### Prerequisites
- `git`, `node >=22.18.0`, `yarn`
- Foundry (`curl -L https://foundry.paradigm.xyz | bash`)

### Local Development
1. **Clone & install** (the OpenZeppelin submodule is required to compile)
```bash
git clone --recurse-submodules <repository-url>
cd microcredit-contract
yarn install
```

2. **Run a local chain**
```bash
yarn chain
```

3. **Deploy contracts with test data** (MockUSDC, a seeded pool and the demo personas)
```bash
yarn deploy
```

4. **Launch the frontend**
```bash
yarn start
```

### Environment Configuration
`yarn deploy` regenerates `packages/nextjs/contracts/deployedContracts.ts`, which the frontend reads for addresses and ABIs; commit it when the contract ABI changes. See the README for optional `packages/nextjs/.env.local` settings.

## Project Structure

```
microcredit-contract/
├── packages/
│   ├── foundry/           # Smart contracts and deployment
│   │   ├── contracts/     # Solidity contracts
│   │   ├── script/        # Forge deployment scripts
│   │   ├── scripts-js/    # Node.js deploy/keystore utilities
│   │   └── test/          # Forge tests
│   └── nextjs/            # Frontend application
│       ├── app/           # Next.js 15 app router pages and relayer API routes
│       ├── components/    # React components
│       ├── hooks/         # Custom React hooks
│       └── utils/         # Shared helpers (deployment constants, EIP-712 types)
├── lib/                   # OpenZeppelin submodule (vendors forge-std)
└── scripts/               # start-anvil.sh, demo.sh, restart.sh, Playwright demo
```

## Testing

### Smart Contract Tests
```bash
# Run all tests
yarn foundry:test

# Run specific tests
cd packages/foundry
forge test --match-test testRequestLoan -vv

# Run tests with gas reporting
forge test --gas-report
```

### Frontend Testing
```bash
# Type checking
yarn next:check-types

# Linting
yarn next:lint

# Production build
yarn next:build
```

## Deployment Considerations

### Local Demo vs Production – Important Notes 🛑

This repository includes demo helpers for local development. **These are NOT meant for production deployments.**

**Important Security Notes:**
- `packages/foundry/script/Deploy.s.sol` contains hard-coded private keys for Anvil development chains only
- Never run deployment scripts with hard-coded keys on public networks
- `Deploy.s.sol` deploys MockUSDC (free mint, no access control) unless `deployment-config.json` points at a live token
- Production deployments require a real USDC contract address

**Best Practices:**
- Run `forge clean` before compilation after major changes
- Use keystore accounts for testnet/mainnet deployments
- Verify contract addresses in `packages/foundry/deployment.json` after deployment

## Code Style and Conventions

### Smart Contracts
- Follow Solidity style guide and OpenZeppelin patterns
- Use meaningful variable names (e.g., `loanAmount` not `amt`)
- Add comprehensive NatSpec documentation
- Prefer explicit over implicit operations
- Use custom errors instead of string reverts

### Frontend
- Use shared formatting helpers from `packages/nextjs/utils/format.ts`
- Reuse components from `packages/nextjs/components/` instead of duplicating
- Follow Next.js 15 App Router conventions
- Use TypeScript strictly (no `any` types)
- Prefer server components when possible

### Testing
- Write descriptive test names that explain the scenario
- Use arrange-act-assert pattern
- Test both happy paths and edge cases
- Include fuzz testing for mathematical operations

## Issues

Issues should be used to report problems, request new features, or discuss potential changes before a PR is created.

### Creating Issues
When creating an issue, please:
- Use a clear and descriptive title
- Provide context about what you were trying to achieve
- Include steps to reproduce for bugs
- Add screenshots or videos when helpful
- Label appropriately (bug, enhancement, documentation, etc.)

### Issue Labels
- `bug` - Something isn't working
- `enhancement` - New feature or improvement
- `documentation` - Documentation updates needed
- `smart-contract` - Contract-related issues
- `frontend` - UI/UX related issues
- `testing` - Test coverage or testing issues

## Pull Requests

### Pull Request Process

We follow the ["fork-and-pull" Git workflow](https://github.com/susam/gitpr)

1. Fork the repo
2. Clone the project
3. Create a new branch with a descriptive name (e.g., `fix/loan-calculation-bug`)
4. Make your changes following the code style guidelines
5. Add tests for new functionality
6. Update documentation if needed
7. Commit your changes with clear commit messages
8. Push changes to your fork
9. Open a PR with a detailed description

### PR Requirements
- Include a clear title and description
- Link to related issues
- Add screenshots/videos for UI changes
- Ensure all tests pass
- Update relevant documentation
- Follow the existing code style

### PR Review Process
- Maintainers will review PRs within a few days
- Address feedback and update your PR as needed
- Mark conversations as resolved after addressing them
- PRs will be squash-merged to keep git history clean

## Development Workflow

### Adding New Features
1. Create an issue to discuss the feature
2. Get feedback from maintainers
3. Create a feature branch
4. Implement with tests
5. Update documentation
6. Submit PR for review

### Fixing Bugs
1. Reproduce the bug locally
2. Write a failing test that demonstrates the bug
3. Fix the bug
4. Ensure the test now passes
5. Submit PR with the fix

### Improving Documentation
- Keep documentation up-to-date with code changes
- Use clear, concise language
- Include code examples where helpful
- Test documentation steps to ensure they work

## Getting Help

- Check existing issues and documentation first
- Join our community discussions
- Ask questions in PR comments
- Tag maintainers when you need input

Thank you for contributing to the Decentralized Microcredit Platform! 🚀
