# SeedDemo Execution Scripts

This directory contains scripts to run the SeedDemo contract 3000 times to create all attestations and loans.

## Background

The SeedDemo contract is designed to create a large ecosystem with:
- 10 lenders (private keys 1-10)
- 300 borrowers (private keys 11-310)
- 3000 attestations (10 lenders × 300 borrowers)
- Loans for all borrowers after all attestations are complete

The contract processes only 1 attestation per run and only creates loans after all attestations are done.

## Scripts

### 1. Python Script (`run_seeddemo.py`)

A Python script that runs SeedDemo 3000 times with proper error handling and progress tracking.

**Usage:**
```bash
# From project root
python packages/foundry/scripts/run_seeddemo.py
```

**Features:**
- Progress tracking
- Error handling and recovery
- Automatic retry logic
- Detailed logging

### 2. Bash Script (`run_seeddemo.sh`)

A simpler bash script alternative.

**Usage:**
```bash
# From project root
bash packages/foundry/scripts/run_seeddemo.sh
```

**Features:**
- Simple execution
- Progress tracking
- Error handling

## Manual Execution

If you prefer to run manually or resume from a specific point:

```bash
cd packages/foundry

# Run with specific START_INDEX (0-2999)
START_INDEX=0 forge script SeedDemo --rpc-url http://localhost:8545 --broadcast

# Resume from where you left off
START_INDEX=1500 forge script SeedDemo --rpc-url http://localhost:8545 --broadcast
```

## Expected Results

After running all 3000 attestations:

1. **300 borrowers** will be created and added to the `_borrowers` array
2. **3000 attestations** will be recorded (10 per borrower)
3. **PageRank scores** will be computed once after all attestations
4. **300 loans** will be created and disbursed

## Troubleshooting

### If the script fails partway through:

1. Note the last successful START_INDEX
2. Resume from that point:
   ```bash
   START_INDEX=<last_successful_index> forge script SeedDemo --rpc-url http://localhost:8545 --broadcast
   ```

### If you need to start over:

1. Redeploy the contracts:
   ```bash
   yarn deploy
   ```
2. Run the execution script again

### RPC Issues:

If you encounter RPC timeouts or rate limiting:
- Increase the sleep delay in the scripts
- Use a different RPC endpoint
- Run in smaller batches

## Verification

After completion, you can verify the results:

1. Check the admin page for 300 borrowers
2. Verify all lenders have made attestations
3. Confirm all borrowers have loans
4. Check PageRank scores are computed 