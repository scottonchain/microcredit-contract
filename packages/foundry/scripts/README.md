# NetworkX PageRank Integration

This directory contains Python scripts for integrating NetworkX PageRank calculations with the DecentralizedMicrocredit smart contract.

## Overview

Instead of implementing PageRank directly in Solidity (which is complex and gas-intensive), we use NetworkX to compute PageRank scores externally and then update the smart contract with the results.

## Files

- `pagerank_calculator.py` - Core PageRank calculation using NetworkX
- `pagerank_oracle.py` - Oracle script for computing and updating PageRank scores
- `integrate_pagerank.py` - Complete demonstration of NetworkX integration
- `networkx_interface.py` - NetworkX interface for testing against Solidity implementation
- `compare_implementations.py` - Script to compare Solidity and NetworkX implementations
- `contract_integration.py` - Integration layer for processing contract data
- `requirements.txt` - Python dependencies
- `README.md` - This documentation

## Installation

1. Install Python dependencies:
```bash
pip install -r requirements.txt
```

## Usage

### Basic PageRank Calculation

```bash
# Run test calculations
python pagerank_calculator.py test

# Compute PageRank from JSON file
python pagerank_calculator.py compute attestations.json
```

### Oracle Integration

```bash
# Run oracle test
python pagerank_oracle.py test

# Process attestation data and update contract
python pagerank_oracle.py compute attestations.json
```

### Complete Integration Demo

```bash
# Run complete NetworkX integration demonstration
python integrate_pagerank.py
```

### Contract Integration

```bash
# Run integration test
python contract_integration.py test

# Process attestation data from JSON
python contract_integration.py process attestations.json
```

## Smart Contract Integration

The smart contract has been simplified to:

1. **Export attestation data** via `exportAttestationData()` function
2. **Use simple scoring** as a placeholder for external PageRank
3. **Support external score updates** (to be implemented)

### Workflow

1. **Collect attestations** in the smart contract
2. **Export data** using `exportAttestationData()`
3. **Compute PageRank** using NetworkX
4. **Update scores** in the smart contract (future enhancement)

## Example JSON Format

```json
{
  "borrowers": ["0x2222", "0x3333"],
  "attesters": [
    ["0x1111", "0x4444"],
    ["0x1111"]
  ],
  "weights": [
    [100000, 200000],
    [300000]
  ]
}
```

## Benefits

- **Proven algorithm**: Uses NetworkX's battle-tested PageRank implementation
- **Gas efficiency**: Complex calculations done off-chain
- **Flexibility**: Easy to modify PageRank parameters
- **Scalability**: Can handle large graphs efficiently

## Future Enhancements

- Web3 integration for direct contract updates
- Batch processing for large datasets
- Real-time score updates
- Integration with oracle networks 