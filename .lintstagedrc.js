module.exports = {
  "packages/nextjs/**/*.{ts,tsx}": [
    "yarn workspace @se-2/nextjs exec eslint --fix",
    () => "yarn next:check-types",
  ],
};
