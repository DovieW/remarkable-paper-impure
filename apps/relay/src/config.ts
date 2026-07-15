import { mkdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parseMasterKey } from "@paperboard/core";

export interface RelayConfig {
  host: string;
  port: number;
  adminHost: string;
  adminPort: number;
  dataDir: string;
  databasePath: string;
  assetsDir: string;
  masterKey: Buffer;
  adminToken: string;
  publicBaseUrl: string;
}

function secret(name: string): string | undefined {
  const file = process.env[`${name}_FILE`];
  if (file) return readFileSync(file, "utf8").trim();
  return process.env[name]?.trim();
}

export function loadConfig(overrides: Partial<RelayConfig> = {}): RelayConfig {
  const dataDir = resolve(overrides.dataDir ?? process.env.PAPERBOARD_DATA_DIR ?? "./data");
  mkdirSync(resolve(dataDir, "assets"), { recursive: true, mode: 0o700 });
  const masterKeyValue = secret("PAPERBOARD_MASTER_KEY");
  const adminToken = overrides.adminToken ?? secret("PAPERBOARD_ADMIN_TOKEN");
  if (!masterKeyValue && !overrides.masterKey) throw new Error("PAPERBOARD_MASTER_KEY or PAPERBOARD_MASTER_KEY_FILE is required");
  if (!adminToken) throw new Error("PAPERBOARD_ADMIN_TOKEN or PAPERBOARD_ADMIN_TOKEN_FILE is required");
  return {
    host: overrides.host ?? process.env.PAPERBOARD_HOST ?? "127.0.0.1",
    port: overrides.port ?? Number(process.env.PAPERBOARD_PORT ?? 8787),
    adminHost: overrides.adminHost ?? process.env.PAPERBOARD_ADMIN_HOST ?? "127.0.0.1",
    adminPort: overrides.adminPort ?? Number(process.env.PAPERBOARD_ADMIN_PORT ?? 8788),
    dataDir,
    databasePath: overrides.databasePath ?? resolve(dataDir, "paperboard.sqlite"),
    assetsDir: overrides.assetsDir ?? resolve(dataDir, "assets"),
    masterKey: overrides.masterKey ?? parseMasterKey(masterKeyValue!),
    adminToken,
    publicBaseUrl: (overrides.publicBaseUrl ?? process.env.PAPERBOARD_PUBLIC_BASE_URL ?? "https://paperboard.invalid").replace(/\/$/, ""),
  };
}
