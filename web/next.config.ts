import type { NextConfig } from "next";
import { writeFileSync } from "node:fs";

// One id per deploy. The service worker and the "new version" banner compare
// against /version.json, so every Vercel deploy reaches every phone and the PC.
const BUILD_ID =
  process.env.VERCEL_GIT_COMMIT_SHA?.slice(0, 8) ??
  process.env.VERCEL_DEPLOYMENT_ID?.slice(-8) ??
  new Date().toISOString().replace(/\D/g, "").slice(0, 14);

writeFileSync(
  "public/version.json",
  JSON.stringify({ version: BUILD_ID, built_at: new Date().toISOString() }) + "\n",
);

const nextConfig: NextConfig = {
  output: "export", // static site: fast, cacheable, works on the old store PC
  trailingSlash: true,
  images: { unoptimized: true },
  env: { NEXT_PUBLIC_BUILD_ID: BUILD_ID },
};

export default nextConfig;
