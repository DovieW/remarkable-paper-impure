import { DatabaseSync } from "node:sqlite";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import type { CardInput, CardPatch, DeliveryCard } from "@paperboard/core";

type DeviceRow = { id: string; token_hash: string; cursor: number; last_seen_at: string | null; last_ack_cursor: number; provider_kind: string };
type ClientRow = { id: string; token_hash: string; scopes: string };
type CardRow = {
  id: string; device_id: string; cursor: number; kind: DeliveryCard["kind"]; title: string; body: string;
  progress: number | null; asset_id: string | null; priority: DeliveryCard["priority"]; pinned: number;
  replace_key: string | null; created_at: string; expires_at: string | null;
};

export interface DeviceStatus {
  id: string;
  cursor: number;
  last_ack_cursor: number;
  last_seen_at: string | null;
  provider: string;
  queued: number;
}

export class Store {
  readonly db: DatabaseSync;
  readonly assetsDir: string;

  constructor(path: string, assetsDir: string) {
    mkdirSync(assetsDir, { recursive: true, mode: 0o700 });
    this.assetsDir = assetsDir;
    this.db = new DatabaseSync(path);
    this.db.exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;");
    this.migrate();
  }

  close(): void { this.db.close(); }

  private transaction<T>(operation: () => T): T {
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const result = operation();
      this.db.exec("COMMIT");
      return result;
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  private migrate(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY, token_hash TEXT NOT NULL, cursor INTEGER NOT NULL DEFAULT 0,
        last_seen_at TEXT, last_ack_cursor INTEGER NOT NULL DEFAULT 0,
        provider_kind TEXT NOT NULL DEFAULT 'none', provider_config TEXT,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
      CREATE TABLE IF NOT EXISTS clients (
        id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, scopes TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
      CREATE TABLE IF NOT EXISTS assets (
        id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        path TEXT NOT NULL, sha256 TEXT NOT NULL, created_at TEXT NOT NULL,
        expires_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS cards (
        id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        cursor INTEGER NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL,
        progress REAL, asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL,
        priority TEXT NOT NULL, pinned INTEGER NOT NULL, replace_key TEXT,
        created_at TEXT NOT NULL, expires_at TEXT
      );
      CREATE UNIQUE INDEX IF NOT EXISTS cards_replace_key ON cards(device_id, replace_key) WHERE replace_key IS NOT NULL;
      CREATE INDEX IF NOT EXISTS cards_device_cursor ON cards(device_id, cursor);
      CREATE TABLE IF NOT EXISTS delivery_log (
        id INTEGER PRIMARY KEY, device_id TEXT NOT NULL, cursor INTEGER NOT NULL,
        action TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS delivery_log_age ON delivery_log(created_at);
      CREATE TABLE IF NOT EXISTS idempotency (
        client_id TEXT NOT NULL, idempotency_key TEXT NOT NULL, response_json TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY(client_id, idempotency_key)
      );
    `);
  }

  createDevice(id: string, tokenHash: string): void {
    this.db.prepare("INSERT INTO devices(id, token_hash) VALUES (?, ?)").run(id, tokenHash);
  }

  rotateDeviceToken(id: string, tokenHash: string): boolean {
    return this.db.prepare("UPDATE devices SET token_hash=? WHERE id=?").run(tokenHash, id).changes === 1;
  }

  createClient(id: string, tokenHash: string, scopes: string[]): void {
    this.db.prepare("INSERT INTO clients(id, token_hash, scopes) VALUES (?, ?, ?)").run(id, tokenHash, scopes.join(" "));
  }

  getDevice(id: string): DeviceRow | undefined {
    return this.db.prepare("SELECT id, token_hash, cursor, last_seen_at, last_ack_cursor, provider_kind FROM devices WHERE id=?").get(id) as DeviceRow | undefined;
  }

  getClientByHash(tokenHash: string): ClientRow | undefined {
    return this.db.prepare("SELECT id, token_hash, scopes FROM clients WHERE token_hash=?").get(tokenHash) as ClientRow | undefined;
  }

  idempotentResponse(clientId: string, key: string): unknown | undefined {
    const row = this.db.prepare("SELECT response_json FROM idempotency WHERE client_id=? AND idempotency_key=?")
      .get(clientId, key) as { response_json: string } | undefined;
    return row ? JSON.parse(row.response_json) : undefined;
  }

  saveIdempotentResponse(clientId: string, key: string, response: unknown): void {
    this.db.prepare("INSERT OR IGNORE INTO idempotency(client_id, idempotency_key, response_json) VALUES (?, ?, ?)")
      .run(clientId, key, JSON.stringify(response));
  }

  private advanceCursor(deviceId: string): number {
    const row = this.db.prepare("UPDATE devices SET cursor=cursor+1 WHERE id=? RETURNING cursor").get(deviceId) as { cursor: number } | undefined;
    if (!row) throw new Error("device not found");
    return row.cursor;
  }

  putAsset(deviceId: string, id: string, path: string, sha256: string, expiresAt: string): void {
    this.db.prepare("INSERT INTO assets(id, device_id, path, sha256, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)")
      .run(id, deviceId, path, sha256, new Date().toISOString(), expiresAt);
  }

  assetPath(deviceId: string, assetId: string): string | undefined {
    const row = this.db.prepare("SELECT path FROM assets WHERE id=? AND device_id=? AND expires_at > ?")
      .get(assetId, deviceId, new Date().toISOString()) as { path: string } | undefined;
    return row?.path;
  }

  createCard(deviceId: string, input: CardInput): CardRow {
    return this.transaction(() => {
      const cursor = this.advanceCursor(deviceId);
      const now = new Date();
      const id = randomUUID().replaceAll("-", "");
      const expiresAt = input.pinned ? null : new Date(now.getTime() + input.ttl_seconds * 1000).toISOString();
      if (input.replace_key) this.db.prepare("DELETE FROM cards WHERE device_id=? AND replace_key=?").run(deviceId, input.replace_key);
      this.db.prepare(`INSERT INTO cards(id, device_id, cursor, kind, title, body, progress, asset_id, priority, pinned, replace_key, created_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(id, deviceId, cursor, input.kind, input.title, input.body, input.progress ?? null, input.asset_id ?? null,
          input.priority, input.pinned ? 1 : 0, input.replace_key ?? null, now.toISOString(), expiresAt);
      this.db.prepare("INSERT INTO delivery_log(device_id, cursor, action) VALUES (?, ?, 'created')").run(deviceId, cursor);
      return this.getCard(deviceId, id)!;
    });
  }

  getCard(deviceId: string, id: string): CardRow | undefined {
    return this.db.prepare("SELECT * FROM cards WHERE device_id=? AND id=?").get(deviceId, id) as CardRow | undefined;
  }

  updateCard(deviceId: string, id: string, patch: CardPatch): CardRow | undefined {
    const current = this.getCard(deviceId, id);
    if (!current) return undefined;
    return this.transaction(() => {
      const cursor = this.advanceCursor(deviceId);
      const title = patch.title ?? current.title;
      const body = patch.body ?? current.body;
      const progress = patch.progress ?? current.progress;
      const priority = patch.priority ?? current.priority;
      const pinned = patch.pinned ?? Boolean(current.pinned);
      let expiresAt = current.expires_at;
      if (pinned) expiresAt = null;
      else if (patch.ttl_seconds) expiresAt = new Date(Date.now() + patch.ttl_seconds * 1000).toISOString();
      this.db.prepare("UPDATE cards SET cursor=?, title=?, body=?, progress=?, priority=?, pinned=?, expires_at=? WHERE device_id=? AND id=?")
        .run(cursor, title, body, progress, priority, pinned ? 1 : 0, expiresAt, deviceId, id);
      this.db.prepare("INSERT INTO delivery_log(device_id, cursor, action) VALUES (?, ?, 'updated')").run(deviceId, cursor);
      return this.getCard(deviceId, id)!;
    });
  }

  deleteCard(deviceId: string, id: string): boolean {
    return this.transaction(() => {
      const removed = this.db.prepare("DELETE FROM cards WHERE device_id=? AND id=?").run(deviceId, id).changes;
      if (!removed) return false;
      const cursor = this.advanceCursor(deviceId);
      this.db.prepare("INSERT INTO delivery_log(device_id, cursor, action) VALUES (?, ?, 'deleted')").run(deviceId, cursor);
      return true;
    });
  }

  clearCards(deviceId: string): number {
    return this.transaction(() => {
      const removed = this.db.prepare("DELETE FROM cards WHERE device_id=?").run(deviceId).changes;
      const cursor = this.advanceCursor(deviceId);
      this.db.prepare("INSERT INTO delivery_log(device_id, cursor, action) VALUES (?, ?, 'cleared')").run(deviceId, cursor);
      return Number(removed);
    });
  }

  activeCards(deviceId: string, assetBaseUrl: string): DeliveryCard[] {
    const now = new Date().toISOString();
    const rows = this.db.prepare(`SELECT * FROM cards WHERE device_id=? AND (pinned=1 OR expires_at>?)
      ORDER BY CASE WHEN priority='urgent' THEN 4 WHEN pinned=1 THEN 3 WHEN priority='normal' THEN 2 ELSE 1 END DESC, created_at DESC`).all(deviceId, now) as CardRow[];
    return rows.map((row) => ({
      id: row.id, cursor: row.cursor, kind: row.kind, title: row.title, body: row.body,
      ...(row.progress === null ? {} : { progress: row.progress }),
      ...(row.asset_id === null ? {} : { asset_url: `${assetBaseUrl}/v1/device/${deviceId}/assets/${row.asset_id}` }),
      priority: row.priority, pinned: Boolean(row.pinned), created_at: row.created_at,
      ...(row.expires_at === null ? {} : { expires_at: row.expires_at }),
    }));
  }

  heartbeat(deviceId: string, cursor?: number): void {
    this.db.prepare("UPDATE devices SET last_seen_at=?, last_ack_cursor=MAX(last_ack_cursor, ?) WHERE id=?")
      .run(new Date().toISOString(), cursor ?? 0, deviceId);
  }

  status(deviceId: string): DeviceStatus | undefined {
    const row = this.db.prepare(`SELECT d.id, d.cursor, d.last_ack_cursor, d.last_seen_at, d.provider_kind AS provider,
      (SELECT COUNT(*) FROM cards c WHERE c.device_id=d.id AND (c.pinned=1 OR c.expires_at>?)) AS queued
      FROM devices d WHERE d.id=?`).get(new Date().toISOString(), deviceId) as DeviceStatus | undefined;
    return row;
  }

  setProvider(deviceId: string, kind: string, encryptedConfig: string | null): boolean {
    const changed = this.db.prepare("UPDATE devices SET provider_kind=?, provider_config=? WHERE id=?").run(kind, encryptedConfig, deviceId).changes;
    if (changed) this.advanceCursor(deviceId);
    return changed === 1;
  }

  getProvider(deviceId: string): { kind: string; encryptedConfig: string | null } | undefined {
    const row = this.db.prepare("SELECT provider_kind AS kind, provider_config AS encryptedConfig FROM devices WHERE id=?").get(deviceId);
    return row as { kind: string; encryptedConfig: string | null } | undefined;
  }

  cleanup(): void {
    const now = new Date().toISOString();
    const staleAssets = this.db.prepare("SELECT path FROM assets WHERE expires_at<=?").all(now) as { path: string }[];
    for (const item of staleAssets) if (existsSync(item.path)) rmSync(item.path, { force: true });
    this.db.prepare("DELETE FROM cards WHERE pinned=0 AND expires_at<=?").run(now);
    this.db.prepare("DELETE FROM assets WHERE expires_at<=?").run(now);
    this.db.prepare("DELETE FROM delivery_log WHERE created_at < datetime('now', '-7 days')").run();
    this.db.prepare("DELETE FROM idempotency WHERE created_at < datetime('now', '-1 day')").run();
  }

  newAssetPath(id: string): string { return join(this.assetsDir, `${id}.png`); }
}
