import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  devIndicators: false,
  typescript: {
    ignoreBuildErrors: process.env.NEXT_PUBLIC_IGNORE_BUILD_ERROR === "true",
  },
  eslint: {
    ignoreDuringBuilds: process.env.NEXT_PUBLIC_IGNORE_BUILD_ERROR === "true",
  },
  webpack: config => {
    config.resolve.fallback = { fs: false, net: false, tls: false };
    config.externals.push("pino-pretty", "lokijs", "encoding");
    return config;
  },
};

const isIpfs = process.env.NEXT_PUBLIC_IPFS_BUILD === "true";

if (isIpfs) {
  nextConfig.output = "export";
  nextConfig.trailingSlash = true;
  // Serve the export under a sub-path (a GitHub Pages project site) when NEXT_PUBLIC_BASE_PATH is set.
  const basePath = process.env.NEXT_PUBLIC_BASE_PATH;
  if (basePath) {
    nextConfig.basePath = basePath;
    nextConfig.assetPrefix = basePath;
  }
  nextConfig.images = {
    unoptimized: true,
  };
}

module.exports = nextConfig;
