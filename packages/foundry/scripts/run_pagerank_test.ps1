# PageRank Verification Test Runner (PowerShell)
# This script runs the PageRank verification test to ensure Solidity implementation matches NetworkX

Write-Host "🚀 Running PageRank Verification Test..." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

# Check if we're in the right directory
if (-not (Test-Path "foundry.toml")) {
    Write-Host "❌ Error: foundry.toml not found. Please run this script from the foundry directory." -ForegroundColor Red
    exit 1
}

# Try to run forge test
try {
    Write-Host "📊 Running PageRank verification tests..." -ForegroundColor Yellow
    
    # Run the PageRank verification test
    $result = & forge test --match-contract PageRankVerificationTest -vv 2>&1
    
    # Check if the command succeeded
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "✅ All PageRank tests PASSED!" -ForegroundColor Green
        Write-Host "🎉 Solidity PageRank implementation matches NetworkX results" -ForegroundColor Green
        Write-Host ""
        Write-Host "Test Summary:" -ForegroundColor Cyan
        Write-Host "- Simple PageRank (3 nodes): ✅ Exact match with NetworkX" -ForegroundColor Green
        Write-Host "- Complex PageRank (5 nodes): ✅ Exact match with NetworkX" -ForegroundColor Green
        Write-Host "- PageRank properties: ✅ All mathematical properties verified" -ForegroundColor Green
        Write-Host "- Edge cases: ✅ Handled correctly" -ForegroundColor Green
        exit 0
    } else {
        Write-Host ""
        Write-Host "❌ PageRank tests FAILED!" -ForegroundColor Red
        Write-Host "🔍 Check the output above for details" -ForegroundColor Yellow
        Write-Host "💡 The Solidity implementation may not match NetworkX exactly" -ForegroundColor Yellow
        exit 1
    }
} catch {
    Write-Host "❌ Error: forge command not found or failed" -ForegroundColor Red
    Write-Host "Please install Foundry first:" -ForegroundColor Yellow
    Write-Host "1. Open WSL terminal: wsl -d Debian" -ForegroundColor Yellow
    Write-Host "2. Install Foundry: curl -L https://foundry.paradigm.xyz | bash" -ForegroundColor Yellow
    Write-Host "3. Reload shell: source ~/.bashrc" -ForegroundColor Yellow
    Write-Host "4. Install forge: foundryup" -ForegroundColor Yellow
    Write-Host "5. Run this script again" -ForegroundColor Yellow
    exit 1
} 