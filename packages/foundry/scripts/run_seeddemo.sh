#!/bin/bash
# Script to run SeedDemo: create borrowers, run all attestations, then finalize

set -e  # Exit on any error

echo "🚀 Starting SeedDemo full execution (borrowers, attestations, finalize)..."
echo "📁 Working directory: $(pwd)"

# Check if we're in the right directory (should be packages/foundry)
if [ ! -f "foundry.toml" ]; then
    echo "❌ Error: foundry.toml not found. Please run from packages/foundry directory."
    exit 1
fi

# 1. Create all borrowers
borrower_total=300
echo "👤 Creating $borrower_total borrowers (one per transaction)..."
for borrower_index in $(seq 0 $((borrower_total - 1))); do
    echo "--- Creating borrower $((borrower_index + 1))/$borrower_total ---"
    if BORROWER_INDEX=$borrower_index ~/.foundry/bin/forge script SeedDemo --rpc-url http://localhost:8545; then
        echo "✅ Successfully created borrower $borrower_index"
    else
        echo "❌ Failed to create borrower $borrower_index"
        exit 1
    fi
    sleep 0.05
    # (shorter delay for borrower creation)
done

echo "👤 All borrowers created."

# 2. Run all attestations
attestation_total=3000
echo "📝 Running $attestation_total attestations (one per transaction)..."
for start_index in $(seq 0 $((attestation_total - 1))); do
    echo "--- Attestation $((start_index + 1))/$attestation_total ---"
    if START_INDEX=$start_index ~/.foundry/bin/forge script SeedDemo --rpc-url http://localhost:8545 --broadcast; then
        echo "✅ Successfully completed attestation $start_index"
    else
        echo "❌ Failed for attestation $start_index"
        exit 1
    fi
    sleep 0.1
done

echo "📝 All attestations complete."

# 3. Finalize (PageRank, loans)
echo "🏁 Running finalization (PageRank, loans)..."
~/.foundry/bin/forge script SeedDemo --rpc-url http://localhost:8545 --broadcast

if [ $? -eq 0 ]; then
    echo "🎊 SeedDemo full execution completed successfully!"
    echo "📊 You should now have 300 borrowers with loans in the system."
else
    echo "❌ Finalization step failed."
    exit 1
fi 