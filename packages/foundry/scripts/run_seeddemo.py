#!/usr/bin/env python3
"""
Script to run SeedDemo 3000 times to create all attestations and loans.
This handles the incremental execution of SeedDemo with different START_INDEX values.
"""

import subprocess
import time
import sys
import os
from pathlib import Path

def run_seeddemo_with_index(start_index, rpc_url="http://localhost:8545"):
    """Run SeedDemo with a specific START_INDEX."""
    try:
        # Set environment variable for START_INDEX
        env = os.environ.copy()
        env['START_INDEX'] = str(start_index)
        
        # Run the forge script
        cmd = [
            "forge", "script", "SeedDemo", 
            "--rpc-url", rpc_url,
            "--broadcast"
        ]
        
        print(f"Running SeedDemo with START_INDEX={start_index}...")
        # Run from current directory (packages/foundry)
        result = subprocess.run(cmd, env=env, capture_output=True, text=True)
        
        if result.returncode == 0:
            print(f"✅ Successfully completed START_INDEX={start_index}")
            return True
        else:
            print(f"❌ Failed for START_INDEX={start_index}")
            print(f"Error: {result.stderr}")
            return False
            
    except Exception as e:
        print(f"❌ Exception for START_INDEX={start_index}: {e}")
        return False

def main():
    """Main function to run all 3000 SeedDemo executions."""
    total_attestations = 3000  # 10 lenders × 300 borrowers
    
    print(f"🚀 Starting SeedDemo execution for {total_attestations} attestations...")
    print(f"📁 Working directory: {os.getcwd()}")
    
    # Check if we're in the right directory (should be packages/foundry)
    if not Path("foundry.toml").exists():
        print("❌ Error: foundry.toml not found. Please run from packages/foundry directory.")
        sys.exit(1)
    
    successful_runs = 0
    failed_runs = 0
    
    # Run all attestations
    for start_index in range(total_attestations):
        print(f"\n--- Progress: {start_index + 1}/{total_attestations} ---")
        
        if run_seeddemo_with_index(start_index):
            successful_runs += 1
        else:
            failed_runs += 1
            print(f"⚠️  Failed at START_INDEX={start_index}. You can resume from this point later.")
            break
        
        # Small delay to avoid overwhelming the RPC
        time.sleep(0.1)
    
    print(f"\n🎉 SeedDemo execution complete!")
    print(f"✅ Successful runs: {successful_runs}")
    print(f"❌ Failed runs: {failed_runs}")
    
    if failed_runs == 0:
        print("🎊 All 3000 attestations completed successfully!")
        print("📊 You should now have 300 borrowers with loans in the system.")
    else:
        print(f"⚠️  To resume from where it failed, run:")
        print(f"   START_INDEX={successful_runs} forge script SeedDemo --rpc-url http://localhost:8545 --broadcast")

if __name__ == "__main__":
    main() 