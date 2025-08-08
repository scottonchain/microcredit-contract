#!/usr/bin/env node

/**
 * Lint-staged script for Hardhat package
 * This script handles the --fix flag and formats files with prettier
 */

const { execSync } = require('child_process');
const path = require('path');

// Get command line arguments
const args = process.argv.slice(2);

// Filter out the --fix flag and get the file names
const files = args.filter(arg => arg !== '--fix');

if (files.length === 0) {
  console.log('No files to format');
  process.exit(0);
}

// Run prettier on the files
try {
  const command = `npx prettier --write --ignore-unknown ${files.join(' ')}`;
  console.log(`Running: ${command}`);
  execSync(command, { stdio: 'inherit', cwd: __dirname });
  console.log('✅ Files formatted successfully');
} catch (error) {
  console.error('❌ Error formatting files:', error.message);
  process.exit(1);
}
