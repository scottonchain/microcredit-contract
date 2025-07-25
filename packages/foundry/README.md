## USDC Deployment

- By default, the deployment script does NOT deploy a mock USDC contract.
- To deploy a mock USDC contract for local testing, set the environment variable `DEPLOY_MOCK_USDC=true` before running `yarn deploy`.
- If you do not set this flag, you must provide a valid USDC address via the `USDC_ADDRESS` environment variable.
- Example for local testing:

```sh
DEPLOY_MOCK_USDC=true yarn deploy
```

- Example for using a real/testnet USDC address:

```sh
USDC_ADDRESS=0x... yarn deploy
``` 