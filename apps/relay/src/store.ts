import { DatabaseSync } from "node:sqlite";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import type { CanvasEventInput, CanvasMessageInput, CardInput, CardPatch, DeliveryCard, PaperboardCommandAction, PaperboardUiState } from "@paperboard/core";

type DeviceRow = { id: string; token_hash: string; cursor: number; last_seen_at: string | null; last_ack_cursor: number; provider_kind: string };
type ClientRow = { id: string; token_hash: string; scopes: string };
type CardRow = {
  id: string; device_id: string; cursor: number; kind: DeliveryCard["kind"]; title: string; body: string;
  progress: number | null; asset_id: string | null; priority: DeliveryCard["priority"]; pinned: number;
  replace_key: string | null; created_at: string; expires_at: string | null;
};
type CommandRow = { id: string; device_id: string; action: PaperboardCommandAction; status: string; detail: string; created_at: string; expires_at: string; completed_at: string | null };
type CanvasSessionRow = { id: string; device_id: string; title: string; status: string; cursor: number; created_at: string; updated_at: string };
type CanvasMessageRow = { id: string; session_id: string; cursor: number; title: string; body: string; asset_id: string | null; actions_json: string; replace_key: string | null; created_at: string };

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
      CREATE TABLE IF NOT EXISTS device_ui_state (
        device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
        application TEXT NOT NULL, state_json TEXT NOT NULL, updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS tablet_commands (
        id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        action TEXT NOT NULL, status TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL, expires_at TEXT NOT NULL, completed_at TEXT
      );
      CREATE INDEX IF NOT EXISTS tablet_commands_device ON tablet_commands(device_id, status, expires_at);
      CREATE TABLE IF NOT EXISTS canvas_sessions (
        id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        title TEXT NOT NULL, status TEXT NOT NULL, cursor INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS canvas_messages (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES canvas_sessions(id) ON DELETE CASCADE,
        cursor INTEGER NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL,
        asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL, actions_json TEXT NOT NULL,
        replace_key TEXT, created_at TEXT NOT NULL
      );
      CREATE UNIQUE INDEX IF NOT EXISTS canvas_messages_replace_key ON canvas_messages(session_id, replace_key) WHERE replace_key IS NOT NULL;
      CREATE TABLE IF NOT EXISTS canvas_events (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES canvas_sessions(id) ON DELETE CASCADE,
        cursor INTEGER NOT NULL, message_id TEXT NOT NULL REFERENCES canvas_messages(id) ON DELETE CASCADE,
        action_id TEXT NOT NULL, value_json TEXT NOT NULL, acknowledged INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
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

  updateClientScopes(id: string, scopes: string[]): boolean {
    return this.db.prepare("UPDATE clients SET scopes=? WHERE id=?").run(scopes.join(" "), id).changes === 1;
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

  listCards(deviceId: string, assetBaseUrl: string): DeliveryCard[] { return this.activeCards(deviceId, assetBaseUrl); }

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

  putUiState(deviceId: string, state: PaperboardUiState): void {
    const now = new Date().toISOString();
    this.db.prepare(`INSERT INTO device_ui_state(device_id, application, state_json, updated_at) VALUES (?, ?, ?, ?)
      ON CONFLICT(device_id) DO UPDATE SET application=excluded.application, state_json=excluded.state_json, updated_at=excluded.updated_at`)
      .run(deviceId, state.application, JSON.stringify(state), now);
    this.heartbeat(deviceId, state.rendered_cursor);
  }

  getUiState(deviceId: string): (PaperboardUiState & { updated_at: string; fresh: boolean }) | undefined {
    const row = this.db.prepare("SELECT state_json, updated_at FROM device_ui_state WHERE device_id=?").get(deviceId) as { state_json: string; updated_at: string } | undefined;
    if (!row) return undefined;
    const state = JSON.parse(row.state_json) as PaperboardUiState;
    const fresh = Date.now() - Date.parse(row.updated_at) <= 10_000;
    return { ...state, foreground: state.foreground && fresh, updated_at: row.updated_at, fresh };
  }

  createCommand(deviceId: string, action: PaperboardCommandAction): CommandRow {
    const now = new Date();
    const id = randomUUID().replaceAll("-", "");
    this.db.prepare("INSERT INTO tablet_commands(id, device_id, action, status, created_at, expires_at) VALUES (?, ?, ?, 'queued', ?, ?)")
      .run(id, deviceId, action, now.toISOString(), new Date(now.getTime() + 15_000).toISOString());
    return this.getCommand(deviceId, id)!;
  }

  getCommand(deviceId: string, id: string): CommandRow | undefined {
    return this.db.prepare("SELECT * FROM tablet_commands WHERE device_id=? AND id=?").get(deviceId, id) as CommandRow | undefined;
  }

  pendingCommands(deviceId: string): CommandRow[] {
    const now = new Date().toISOString();
    this.db.prepare("UPDATE tablet_commands SET status='expired', completed_at=? WHERE device_id=? AND status IN ('queued','delivered') AND expires_at<=?").run(now, deviceId, now);
    const rows = this.db.prepare("SELECT * FROM tablet_commands WHERE device_id=? AND status='queued' AND expires_at>? ORDER BY created_at").all(deviceId, now) as CommandRow[];
    for (const row of rows) this.db.prepare("UPDATE tablet_commands SET status='delivered' WHERE id=?").run(row.id);
    return rows.map((row) => ({ ...row, status: "delivered" }));
  }

  finishCommand(deviceId: string, id: string, status: "completed" | "failed", detail: string): boolean {
    return this.db.prepare("UPDATE tablet_commands SET status=?, detail=?, completed_at=? WHERE device_id=? AND id=? AND status IN ('queued','delivered')")
      .run(status, detail, new Date().toISOString(), deviceId, id).changes === 1;
  }

  createCanvasSession(deviceId: string, title: string): CanvasSessionRow {
    const id = randomUUID().replaceAll("-", ""); const now = new Date().toISOString();
    this.db.prepare("INSERT INTO canvas_sessions(id, device_id, title, status, created_at, updated_at) VALUES (?, ?, ?, 'open', ?, ?)").run(id, deviceId, title, now, now);
    return this.getCanvasSession(deviceId, id)!;
  }

  getCanvasSession(deviceId: string, id: string): CanvasSessionRow | undefined {
    return this.db.prepare("SELECT * FROM canvas_sessions WHERE device_id=? AND id=?").get(deviceId, id) as CanvasSessionRow | undefined;
  }

  listCanvasSessions(deviceId: string): CanvasSessionRow[] {
    return this.db.prepare("SELECT * FROM canvas_sessions WHERE device_id=? ORDER BY updated_at DESC").all(deviceId) as CanvasSessionRow[];
  }

  latestOpenCanvasSession(deviceId: string): CanvasSessionRow | undefined {
    return this.db.prepare("SELECT * FROM canvas_sessions WHERE device_id=? AND status='open' ORDER BY updated_at DESC LIMIT 1").get(deviceId) as CanvasSessionRow | undefined;
  }

  closeCanvasSession(deviceId: string, id: string): boolean {
    return this.db.prepare("UPDATE canvas_sessions SET status='closed', updated_at=? WHERE device_id=? AND id=?").run(new Date().toISOString(), deviceId, id).changes === 1;
  }

  createCanvasMessage(deviceId: string, sessionId: string, input: CanvasMessageInput): CanvasMessageRow | undefined {
    const session = this.getCanvasSession(deviceId, sessionId); if (!session || session.status !== "open") return undefined;
    return this.transaction(() => {
      const cursor = session.cursor + 1; const id = randomUUID().replaceAll("-", ""); const now = new Date().toISOString();
      if (input.replace_key) this.db.prepare("DELETE FROM canvas_messages WHERE session_id=? AND replace_key=?").run(sessionId, input.replace_key);
      this.db.prepare("INSERT INTO canvas_messages(id, session_id, cursor, title, body, asset_id, actions_json, replace_key, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
        .run(id, sessionId, cursor, input.title, input.body, input.asset_id ?? null, JSON.stringify(input.actions), input.replace_key ?? null, now);
      this.db.prepare("UPDATE canvas_sessions SET cursor=?, updated_at=? WHERE id=?").run(cursor, now, sessionId);
      return this.getCanvasMessage(sessionId, id)!;
    });
  }

  getCanvasMessage(sessionId: string, id: string): CanvasMessageRow | undefined {
    return this.db.prepare("SELECT * FROM canvas_messages WHERE session_id=? AND id=?").get(sessionId, id) as CanvasMessageRow | undefined;
  }

  canvasMessages(deviceId: string, sessionId: string, assetBaseUrl?: string): Array<Record<string, unknown>> {
    if (!this.getCanvasSession(deviceId, sessionId)) return [];
    const rows = this.db.prepare("SELECT * FROM canvas_messages WHERE session_id=? ORDER BY cursor").all(sessionId) as CanvasMessageRow[];
    return rows.map((row) => ({ id: row.id, cursor: row.cursor, title: row.title, body: row.body, asset_id: row.asset_id,
      ...(row.asset_id && assetBaseUrl ? { asset_url: `${assetBaseUrl}/v1/device/${deviceId}/assets/${row.asset_id}` } : {}),
      actions: JSON.parse(row.actions_json), created_at: row.created_at }));
  }

  createCanvasEvent(deviceId: string, sessionId: string, input: CanvasEventInput): Record<string, unknown> | undefined {
    if (!this.getCanvasSession(deviceId, sessionId) || !this.getCanvasMessage(sessionId, input.message_id)) return undefined;
    const id = randomUUID().replaceAll("-", ""); const now = new Date().toISOString();
    const cursor = Number((this.db.prepare("SELECT COALESCE(MAX(cursor),0)+1 AS cursor FROM canvas_events WHERE session_id=?").get(sessionId) as { cursor: number }).cursor);
    this.db.prepare("INSERT INTO canvas_events(id, session_id, cursor, message_id, action_id, value_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
      .run(id, sessionId, cursor, input.message_id, input.action_id, JSON.stringify(input.value), now);
    return { id, cursor, ...input, created_at: now };
  }

  canvasEvents(deviceId: string, sessionId: string, after = 0): Array<Record<string, unknown>> {
    if (!this.getCanvasSession(deviceId, sessionId)) return [];
    const rows = this.db.prepare("SELECT * FROM canvas_events WHERE session_id=? AND cursor>? ORDER BY cursor").all(sessionId, after) as Array<{ id: string; cursor: number; message_id: string; action_id: string; value_json: string; acknowledged: number; created_at: string }>;
    return rows.map((row) => ({ ...row, value: JSON.parse(row.value_json), value_json: undefined, acknowledged: Boolean(row.acknowledged) }));
  }

  acknowledgeCanvasEvent(deviceId: string, sessionId: string, eventId: string): boolean {
    if (!this.getCanvasSession(deviceId, sessionId)) return false;
    return this.db.prepare("UPDATE canvas_events SET acknowledged=1 WHERE session_id=? AND id=?").run(sessionId, eventId).changes === 1;
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
    this.db.prepare("DELETE FROM tablet_commands WHERE created_at < datetime('now', '-1 day')").run();
    this.db.prepare("DELETE FROM canvas_events WHERE created_at < datetime('now', '-7 days')").run();
  }

  newAssetPath(id: string): string { return join(this.assetsDir, `${id}.png`); }
}
