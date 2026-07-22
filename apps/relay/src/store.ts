import { DatabaseSync } from "node:sqlite";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { decryptSecret, encryptSecret, type CanvasEventInput, type CanvasMessageInput, type CardInput, type CardPatch, type ChatAction, type ChatBridgeSync, type DeliveryCard, type PaperboardCommandAction, type PaperboardUiState } from "@paperboard/core";

type DeviceRow = { id: string; token_hash: string; cursor: number; last_seen_at: string | null; last_ack_cursor: number; provider_kind: string };
type ClientRow = { id: string; token_hash: string; scopes: string; created_at?: string; last_used_at?: string | null; revoked_at?: string | null };
type CardRow = {
  id: string; device_id: string; cursor: number; kind: DeliveryCard["kind"]; title: string; body: string;
  progress: number | null; asset_id: string | null; priority: DeliveryCard["priority"]; pinned: number;
  replace_key: string | null; created_at: string; expires_at: string | null;
};
type CommandRow = { id: string; device_id: string; action: PaperboardCommandAction; target_id: string | null; status: string; detail: string; created_at: string; expires_at: string; completed_at: string | null };
type CanvasSessionRow = { id: string; device_id: string; title: string; status: string; cursor: number; created_at: string; updated_at: string };
type CanvasMessageRow = { id: string; session_id: string; cursor: number; title: string; body: string; asset_id: string | null; actions_json: string; replace_key: string | null; created_at: string };
type CanvasHistoryRow = CanvasMessageRow & { session_title: string };
export interface ReaderBookmark { url: string; title: string; created_at: string; }

export const CANVAS_HISTORY_LIMIT = 100;

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
  readonly masterKey: Buffer;

  constructor(path: string, assetsDir: string, masterKey: Buffer) {
    mkdirSync(assetsDir, { recursive: true, mode: 0o700 });
    this.assetsDir = assetsDir;
    this.masterKey = masterKey;
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
    this.db.exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
      version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )`);
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY, token_hash TEXT NOT NULL, cursor INTEGER NOT NULL DEFAULT 0,
        canvas_cursor INTEGER NOT NULL DEFAULT 0,
        screen_target_id TEXT,
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
        action TEXT NOT NULL, target_id TEXT, status TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '',
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
      CREATE INDEX IF NOT EXISTS canvas_messages_session_cursor ON canvas_messages(session_id, cursor);
      CREATE TABLE IF NOT EXISTS canvas_events (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES canvas_sessions(id) ON DELETE CASCADE,
        cursor INTEGER NOT NULL, message_id TEXT NOT NULL REFERENCES canvas_messages(id) ON DELETE CASCADE,
        action_id TEXT NOT NULL, value_json TEXT NOT NULL, acknowledged INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      );
    `);
    const deviceColumns = this.db.prepare("PRAGMA table_info(devices)").all() as Array<{ name: string }>;
    if (!deviceColumns.some((column) => column.name === "canvas_cursor")) {
      this.db.exec("ALTER TABLE devices ADD COLUMN canvas_cursor INTEGER NOT NULL DEFAULT 0");
      this.db.exec(`
        UPDATE devices SET canvas_cursor = (
          SELECT COUNT(*) + (SELECT COUNT(*) FROM canvas_sessions WHERE device_id=devices.id)
          FROM canvas_messages
          JOIN canvas_sessions ON canvas_sessions.id=canvas_messages.session_id
          WHERE canvas_sessions.device_id=devices.id
        )
      `);
    }
    if (!deviceColumns.some((column) => column.name === "screen_target_id")) this.db.exec("ALTER TABLE devices ADD COLUMN screen_target_id TEXT");
    this.db.prepare("INSERT OR IGNORE INTO schema_migrations(version, name) VALUES (1, 'legacy-foundation')").run();
    const clientColumns = this.db.prepare("PRAGMA table_info(clients)").all() as Array<{ name: string }>;
    if (!clientColumns.some((column) => column.name === "last_used_at")) this.db.exec("ALTER TABLE clients ADD COLUMN last_used_at TEXT");
    if (!clientColumns.some((column) => column.name === "revoked_at")) this.db.exec("ALTER TABLE clients ADD COLUMN revoked_at TEXT");
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS audit_events (
        id INTEGER PRIMARY KEY, request_id TEXT NOT NULL, actor_id TEXT NOT NULL,
        operation TEXT NOT NULL, device_id TEXT, outcome TEXT NOT NULL,
        metadata_json TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS audit_events_age ON audit_events(created_at);
    `);
    this.db.prepare("INSERT OR IGNORE INTO schema_migrations(version, name) VALUES (2, 'v2-security-and-audit')").run();
    const commandColumns = this.db.prepare("PRAGMA table_info(tablet_commands)").all() as Array<{ name: string }>;
    if (!commandColumns.some((column) => column.name === "target_id")) this.db.exec("ALTER TABLE tablet_commands ADD COLUMN target_id TEXT");
    this.db.prepare("INSERT OR IGNORE INTO schema_migrations(version, name) VALUES (3, 'targeted-screen-presentation')").run();
    this.db.prepare("INSERT OR IGNORE INTO schema_migrations(version, name) VALUES (4, 'durable-screen-presentation')").run();
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS reader_bookmarks (
        device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        url TEXT NOT NULL, title TEXT NOT NULL, created_at TEXT NOT NULL,
        PRIMARY KEY(device_id, url)
      );
      CREATE INDEX IF NOT EXISTS reader_bookmarks_device_age ON reader_bookmarks(device_id, created_at DESC);
    `);
    this.db.prepare("INSERT OR IGNORE INTO schema_migrations(version, name) VALUES (5, 'reader-bookmarks')").run();
    const currentDeviceColumns = this.db.prepare("PRAGMA table_info(devices)").all() as Array<{ name: string }>;
    if (!currentDeviceColumns.some((column) => column.name === "chat_cursor")) this.db.exec("ALTER TABLE devices ADD COLUMN chat_cursor INTEGER NOT NULL DEFAULT 0");
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS chat_agents (
        device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        id TEXT NOT NULL, name_enc TEXT NOT NULL, updated_at TEXT NOT NULL,
        PRIMARY KEY(device_id, id)
      );
      CREATE TABLE IF NOT EXISTS chat_sessions (
        device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        session_key TEXT NOT NULL, agent_id TEXT NOT NULL, channel TEXT NOT NULL,
        title_enc TEXT NOT NULL, updated_at TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0,
        pinned INTEGER NOT NULL DEFAULT 0, hidden INTEGER NOT NULL DEFAULT 0,
        unread INTEGER NOT NULL DEFAULT 0, run_status TEXT NOT NULL DEFAULT 'idle', run_id TEXT,
        PRIMARY KEY(device_id, session_key)
      );
      CREATE INDEX IF NOT EXISTS chat_sessions_recent ON chat_sessions(device_id, hidden, updated_at DESC);
      CREATE TABLE IF NOT EXISTS chat_messages (
        device_id TEXT NOT NULL, id TEXT NOT NULL, session_key TEXT NOT NULL,
        role TEXT NOT NULL, status TEXT NOT NULL, body_enc TEXT NOT NULL, asset_id TEXT,
        run_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        PRIMARY KEY(device_id, id),
        FOREIGN KEY(device_id, session_key) REFERENCES chat_sessions(device_id, session_key) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS chat_messages_session ON chat_messages(device_id, session_key, created_at);
      CREATE TABLE IF NOT EXISTS chat_actions (
        id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        kind TEXT NOT NULL, payload_enc TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued',
        attempts INTEGER NOT NULL DEFAULT 0, detail TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS chat_actions_pending ON chat_actions(device_id, status, created_at);
      CREATE TABLE IF NOT EXISTS chat_bridge_state (
        device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
        last_seen_at TEXT, last_error TEXT
      );
    `);
    this.db.prepare("INSERT OR IGNORE INTO schema_migrations(version, name) VALUES (6, 'encrypted-paperchat')").run();
    const chatActionColumns = this.db.prepare("PRAGMA table_info(chat_actions)").all() as Array<{ name: string }>;
    if (!chatActionColumns.some((column) => column.name === "worker_id")) this.db.exec("ALTER TABLE chat_actions ADD COLUMN worker_id TEXT");
    if (!chatActionColumns.some((column) => column.name === "lease_expires_at")) this.db.exec("ALTER TABLE chat_actions ADD COLUMN lease_expires_at TEXT");
    this.db.prepare("INSERT OR IGNORE INTO schema_migrations(version, name) VALUES (7, 'paperchat-action-leases')").run();
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
    const row = this.db.prepare("SELECT id, token_hash, scopes, created_at, last_used_at, revoked_at FROM clients WHERE token_hash=? AND revoked_at IS NULL").get(tokenHash) as ClientRow | undefined;
    if (row) this.db.prepare("UPDATE clients SET last_used_at=? WHERE id=?").run(new Date().toISOString(), row.id);
    return row;
  }

  listClients(): Array<Omit<ClientRow, "token_hash">> {
    return this.db.prepare("SELECT id, scopes, created_at, last_used_at, revoked_at FROM clients ORDER BY id").all() as Array<Omit<ClientRow, "token_hash">>;
  }

  revokeClient(id: string): boolean {
    return this.db.prepare("UPDATE clients SET revoked_at=? WHERE id=? AND revoked_at IS NULL").run(new Date().toISOString(), id).changes === 1;
  }

  audit(requestId: string, actorId: string, operation: string, deviceId: string | null, outcome: string, metadata: Record<string, unknown> = {}): void {
    this.db.prepare("INSERT INTO audit_events(request_id, actor_id, operation, device_id, outcome, metadata_json) VALUES (?, ?, ?, ?, ?, ?)")
      .run(requestId, actorId, operation, deviceId, outcome, JSON.stringify(metadata));
  }

  migrationStatus(): Array<{ version: number; name: string; applied_at: string }> {
    return this.db.prepare("SELECT version, name, applied_at FROM schema_migrations ORDER BY version").all() as Array<{ version: number; name: string; applied_at: string }>;
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
      ...(row.asset_id === null ? {} : { asset_url: `${assetBaseUrl}/v2/device/${deviceId}/assets/${row.asset_id}` }),
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
    if (state.active_message_id) {
      this.db.prepare("UPDATE devices SET screen_target_id=NULL WHERE id=? AND screen_target_id=?")
        .run(deviceId, state.active_message_id);
    }
  }

  requestScreenPresentation(deviceId: string, messageId: string): void {
    this.db.prepare("UPDATE devices SET screen_target_id=? WHERE id=?").run(messageId, deviceId);
  }

  screenPresentationTarget(deviceId: string): string | null {
    const row = this.db.prepare("SELECT screen_target_id FROM devices WHERE id=?").get(deviceId) as { screen_target_id: string | null } | undefined;
    return row?.screen_target_id ?? null;
  }

  getUiState(deviceId: string): (PaperboardUiState & { updated_at: string; fresh: boolean }) | undefined {
    const row = this.db.prepare("SELECT state_json, updated_at FROM device_ui_state WHERE device_id=?").get(deviceId) as { state_json: string; updated_at: string } | undefined;
    if (!row) return undefined;
    const state = JSON.parse(row.state_json) as PaperboardUiState;
    const fresh = Date.now() - Date.parse(row.updated_at) <= 10_000;
    return { ...state, foreground: state.foreground && fresh, updated_at: row.updated_at, fresh };
  }

  readerBookmarks(deviceId: string): ReaderBookmark[] {
    return this.db.prepare("SELECT url, title, created_at FROM reader_bookmarks WHERE device_id=? ORDER BY created_at DESC LIMIT 100")
      .all(deviceId) as unknown as ReaderBookmark[];
  }

  isReaderBookmark(deviceId: string, url: string): boolean {
    return Boolean(this.db.prepare("SELECT 1 FROM reader_bookmarks WHERE device_id=? AND url=?").get(deviceId, url));
  }

  toggleReaderBookmark(deviceId: string, url: string, title: string): { bookmarked: boolean; bookmarks: ReaderBookmark[] } {
    const existing = this.db.prepare("SELECT 1 FROM reader_bookmarks WHERE device_id=? AND url=?").get(deviceId, url);
    if (existing) this.db.prepare("DELETE FROM reader_bookmarks WHERE device_id=? AND url=?").run(deviceId, url);
    else {
      this.db.prepare("INSERT INTO reader_bookmarks(device_id, url, title, created_at) VALUES (?, ?, ?, ?)")
        .run(deviceId, url, title, new Date().toISOString());
      this.db.prepare(`DELETE FROM reader_bookmarks WHERE device_id=? AND url IN (
        SELECT url FROM reader_bookmarks WHERE device_id=? ORDER BY created_at DESC LIMIT -1 OFFSET 100
      )`).run(deviceId, deviceId);
    }
    return { bookmarked: !existing, bookmarks: this.readerBookmarks(deviceId) };
  }

  createCommand(deviceId: string, action: PaperboardCommandAction, targetId: string | null = null): CommandRow {
    const now = new Date();
    const id = randomUUID().replaceAll("-", "");
    this.db.prepare("INSERT INTO tablet_commands(id, device_id, action, target_id, status, created_at, expires_at) VALUES (?, ?, ?, ?, 'queued', ?, ?)")
      .run(id, deviceId, action, targetId, now.toISOString(), new Date(now.getTime() + 15_000).toISOString());
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
    return this.transaction(() => {
      const id = randomUUID().replaceAll("-", ""); const now = new Date().toISOString();
      this.db.prepare("INSERT INTO canvas_sessions(id, device_id, title, status, created_at, updated_at) VALUES (?, ?, ?, 'open', ?, ?)").run(id, deviceId, title, now, now);
      this.advanceCanvasCursor(deviceId);
      return this.getCanvasSession(deviceId, id)!;
    });
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
    return this.transaction(() => {
      const closed = this.db.prepare("UPDATE canvas_sessions SET status='closed', updated_at=? WHERE device_id=? AND id=?").run(new Date().toISOString(), deviceId, id).changes === 1;
      if (closed) this.advanceCanvasCursor(deviceId);
      return closed;
    });
  }

  canvasCursor(deviceId: string): number {
    return Number((this.db.prepare("SELECT canvas_cursor FROM devices WHERE id=?").get(deviceId) as { canvas_cursor?: number } | undefined)?.canvas_cursor ?? 0);
  }

  private advanceCanvasCursor(deviceId: string): void {
    this.db.prepare("UPDATE devices SET canvas_cursor=canvas_cursor+1 WHERE id=?").run(deviceId);
  }

  private pruneCanvasHistory(deviceId: string): void {
    this.db.prepare(`
      DELETE FROM canvas_messages WHERE id IN (
        SELECT message.id
        FROM canvas_messages AS message
        JOIN canvas_sessions AS session ON session.id=message.session_id
        WHERE session.device_id=?
        ORDER BY message.created_at DESC, message.rowid DESC
        LIMIT -1 OFFSET ?
      )
    `).run(deviceId, CANVAS_HISTORY_LIMIT);
  }

  createCanvasMessage(deviceId: string, sessionId: string, input: CanvasMessageInput): CanvasMessageRow | undefined {
    const session = this.getCanvasSession(deviceId, sessionId); if (!session || session.status !== "open") return undefined;
    return this.transaction(() => {
      const cursor = session.cursor + 1; const id = randomUUID().replaceAll("-", ""); const now = new Date().toISOString();
      if (input.replace_key) this.db.prepare("DELETE FROM canvas_messages WHERE session_id=? AND replace_key=?").run(sessionId, input.replace_key);
      this.db.prepare("INSERT INTO canvas_messages(id, session_id, cursor, title, body, asset_id, actions_json, replace_key, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
        .run(id, sessionId, cursor, input.title, input.body, input.asset_id ?? null, JSON.stringify(input.actions), input.replace_key ?? null, now);
      this.db.prepare("UPDATE canvas_sessions SET cursor=?, updated_at=? WHERE id=?").run(cursor, now, sessionId);
      this.advanceCanvasCursor(deviceId);
      this.pruneCanvasHistory(deviceId);
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
      ...(row.asset_id && assetBaseUrl ? { asset_url: `${assetBaseUrl}/v2/device/${deviceId}/assets/${row.asset_id}` } : {}),
      actions: JSON.parse(row.actions_json), created_at: row.created_at }));
  }

  canvasHistory(deviceId: string, assetBaseUrl?: string): Array<Record<string, unknown>> {
    const rows = this.db.prepare(`
      SELECT message.*, session.title AS session_title
      FROM canvas_messages AS message
      JOIN canvas_sessions AS session ON session.id=message.session_id
      WHERE session.device_id=?
      ORDER BY message.created_at DESC, message.rowid DESC
      LIMIT ?
    `).all(deviceId, CANVAS_HISTORY_LIMIT) as CanvasHistoryRow[];
    return rows.reverse().map((row) => ({
      id: row.id, session_id: row.session_id, session_title: row.session_title,
      cursor: row.cursor, title: row.title, body: row.body, asset_id: row.asset_id,
      ...(row.asset_id && assetBaseUrl ? { asset_url: `${assetBaseUrl}/v2/device/${deviceId}/assets/${row.asset_id}` } : {}),
      actions: JSON.parse(row.actions_json), created_at: row.created_at,
    }));
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

  private advanceChatCursor(deviceId: string): number {
    this.db.prepare("UPDATE devices SET chat_cursor=chat_cursor+1 WHERE id=?").run(deviceId);
    return Number((this.db.prepare("SELECT chat_cursor FROM devices WHERE id=?").get(deviceId) as { chat_cursor: number } | undefined)?.chat_cursor ?? 0);
  }

  chatCursor(deviceId: string): number {
    return Number((this.db.prepare("SELECT chat_cursor FROM devices WHERE id=?").get(deviceId) as { chat_cursor: number } | undefined)?.chat_cursor ?? 0);
  }

  applyChatAction(deviceId: string, action: ChatAction): void {
    const now = new Date().toISOString();
    this.transaction(() => {
      const localOnly = action.kind === "pin" || action.kind === "hide" || action.kind === "restore" || action.kind === "mark_read";
      const inserted = this.db.prepare(`INSERT OR IGNORE INTO chat_actions(id,device_id,kind,payload_enc,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?)`)
        .run(action.id, deviceId, action.kind, encryptSecret(JSON.stringify(action), this.masterKey), localOnly ? "completed" : "queued", now, now);
      if (inserted.changes === 0) return;
      if (action.kind === "pin" || action.kind === "hide" || action.kind === "restore" || action.kind === "mark_read") {
        const column = action.kind === "pin" ? "pinned" : action.kind === "mark_read" ? "unread" : "hidden";
        const value = action.kind === "restore" ? 0 : action.kind === "mark_read" ? 0 : action.value ? 1 : 0;
        this.db.prepare(`UPDATE chat_sessions SET ${column}=?, updated_at=? WHERE device_id=? AND session_key=?`).run(value, now, deviceId, action.session_key);
      } else {
        if (action.kind === "create") {
          this.db.prepare(`INSERT OR IGNORE INTO chat_sessions(device_id,session_key,agent_id,channel,title_enc,updated_at)
            VALUES(?,?,?,?,?,?)`).run(deviceId, action.session_key, action.agent_id, "paperchat", encryptSecret(action.title, this.masterKey), now);
        }
        if (action.kind === "send" || action.kind === "retry") {
          this.db.prepare(`INSERT INTO chat_messages(device_id,id,session_key,role,status,body_enc,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(device_id,id) DO UPDATE SET status='queued', body_enc=excluded.body_enc, updated_at=excluded.updated_at`)
            .run(deviceId, action.message_id, action.session_key, "user", "queued", encryptSecret(action.text, this.masterKey), now, now);
        }
      }
      this.advanceChatCursor(deviceId);
    });
  }

  claimChatAction(deviceId: string, workerId: string, leaseSeconds: number): (ChatAction & { lease_expires_at: string; attempts: number }) | null {
    return this.transaction(() => {
      const now = new Date().toISOString();
      const expired = this.db.prepare(`SELECT id,payload_enc FROM chat_actions WHERE device_id=? AND status='processing' AND lease_expires_at IS NOT NULL AND lease_expires_at<=?`)
        .all(deviceId, now) as Array<{ id: string; payload_enc: string }>;
      for (const row of expired) {
        this.db.prepare(`UPDATE chat_actions SET status='failed',detail='Bridge interrupted; retry explicitly.',worker_id=NULL,lease_expires_at=NULL,updated_at=? WHERE id=?`)
          .run(now, row.id);
        const action = JSON.parse(decryptSecret(row.payload_enc, this.masterKey)) as ChatAction;
        if (action.kind === "send" || action.kind === "retry") this.db.prepare("UPDATE chat_messages SET status='failed',updated_at=? WHERE device_id=? AND id=?")
          .run(now, deviceId, action.message_id);
      }
      if (expired.length) this.advanceChatCursor(deviceId);
      const row = this.db.prepare("SELECT id,payload_enc FROM chat_actions WHERE device_id=? AND status='queued' ORDER BY created_at LIMIT 1")
        .get(deviceId) as { id: string; payload_enc: string } | undefined;
      if (!row) return null;
      const leaseExpiresAt = new Date(Date.now() + leaseSeconds * 1000).toISOString();
      const claimed = this.db.prepare(`UPDATE chat_actions SET status='processing',attempts=attempts+1,worker_id=?,lease_expires_at=?,detail='',updated_at=?
        WHERE device_id=? AND id=? AND status='queued'`).run(workerId, leaseExpiresAt, now, deviceId, row.id);
      if (claimed.changes !== 1) return null;
      const action = JSON.parse(decryptSecret(row.payload_enc, this.masterKey)) as ChatAction;
      if (action.kind === "send" || action.kind === "retry") this.db.prepare("UPDATE chat_messages SET status='streaming',updated_at=? WHERE device_id=? AND id=?")
        .run(now, deviceId, action.message_id);
      const attempts = Number((this.db.prepare("SELECT attempts FROM chat_actions WHERE id=?").get(row.id) as { attempts: number }).attempts);
      this.advanceChatCursor(deviceId);
      return { ...action, lease_expires_at: leaseExpiresAt, attempts };
    });
  }

  renewChatActionLease(deviceId: string, actionId: string, workerId: string, leaseSeconds: number): boolean {
    const now = new Date().toISOString();
    const leaseExpiresAt = new Date(Date.now() + leaseSeconds * 1000).toISOString();
    return this.db.prepare(`UPDATE chat_actions SET lease_expires_at=?,updated_at=?
      WHERE device_id=? AND id=? AND status='processing' AND worker_id=?`).run(leaseExpiresAt, now, deviceId, actionId, workerId).changes === 1;
  }

  deleteChatSession(deviceId: string, sessionKey: string): boolean {
    return this.transaction(() => {
      const exists = this.db.prepare("SELECT 1 FROM chat_sessions WHERE device_id=? AND session_key=?")
        .get(deviceId, sessionKey);
      if (!exists) return false;
      const actions = this.db.prepare("SELECT id,payload_enc FROM chat_actions WHERE device_id=?")
        .all(deviceId) as Array<{ id: string; payload_enc: string }>;
      for (const row of actions) {
        const action = JSON.parse(decryptSecret(row.payload_enc, this.masterKey)) as ChatAction;
        if (action.session_key === sessionKey) this.db.prepare("DELETE FROM chat_actions WHERE id=?").run(row.id);
      }
      this.db.prepare("DELETE FROM chat_sessions WHERE device_id=? AND session_key=?").run(deviceId, sessionKey);
      this.advanceChatCursor(deviceId);
      return true;
    });
  }

  syncChat(deviceId: string, input: ChatBridgeSync): void {
    const now = new Date().toISOString();
    this.transaction(() => {
      for (const agent of input.agents) this.db.prepare(`INSERT INTO chat_agents(device_id,id,name_enc,updated_at) VALUES(?,?,?,?)
        ON CONFLICT(device_id,id) DO UPDATE SET name_enc=excluded.name_enc,updated_at=excluded.updated_at`)
        .run(deviceId, agent.id, encryptSecret(agent.name, this.masterKey), now);
      for (const session of input.sessions) this.db.prepare(`INSERT INTO chat_sessions(device_id,session_key,agent_id,channel,title_enc,updated_at,archived,run_status,run_id)
        VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(device_id,session_key) DO UPDATE SET agent_id=excluded.agent_id,channel=excluded.channel,
        title_enc=excluded.title_enc,updated_at=excluded.updated_at,archived=excluded.archived,run_status=excluded.run_status,run_id=excluded.run_id`)
        .run(deviceId, session.session_key, session.agent_id, session.channel, encryptSecret(session.title, this.masterKey), session.updated_at, session.archived ? 1 : 0, session.run_status, session.run_id);
      for (const message of input.messages) this.db.prepare(`INSERT INTO chat_messages(device_id,id,session_key,role,status,body_enc,asset_id,run_id,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(device_id,id) DO UPDATE SET status=excluded.status,body_enc=excluded.body_enc,
        asset_id=excluded.asset_id,run_id=excluded.run_id,updated_at=excluded.updated_at`)
        .run(deviceId, message.id, message.session_key, message.role, message.status, encryptSecret(message.body, this.masterKey), message.asset_id, message.run_id, message.created_at, now);
      for (const receipt of input.receipts) {
        const row = this.db.prepare("SELECT payload_enc FROM chat_actions WHERE device_id=? AND id=?").get(deviceId, receipt.id) as { payload_enc: string } | undefined;
        this.db.prepare("UPDATE chat_actions SET status=?,detail=?,worker_id=NULL,lease_expires_at=NULL,updated_at=? WHERE device_id=? AND id=? AND status NOT IN ('completed','failed')")
          .run(receipt.status, receipt.detail, now, deviceId, receipt.id);
        if (row) {
          const action = JSON.parse(decryptSecret(row.payload_enc, this.masterKey)) as ChatAction;
          if (action.kind === "send" || action.kind === "retry") this.db.prepare("UPDATE chat_messages SET status=?,updated_at=? WHERE device_id=? AND id=?")
            .run(receipt.status === "completed" ? "complete" : "failed", now, deviceId, action.message_id);
        }
      }
      this.db.prepare(`INSERT INTO chat_bridge_state(device_id,last_seen_at,last_error) VALUES(?,?,?)
        ON CONFLICT(device_id) DO UPDATE SET last_seen_at=excluded.last_seen_at,last_error=excluded.last_error`).run(deviceId, now, input.error);
      for (const session of input.sessions) this.db.prepare(`DELETE FROM chat_messages WHERE rowid IN (SELECT rowid FROM chat_messages WHERE device_id=? AND session_key=? ORDER BY created_at DESC LIMIT -1 OFFSET 500)`).run(deviceId, session.session_key);
      this.db.prepare(`DELETE FROM chat_sessions WHERE rowid IN (SELECT rowid FROM chat_sessions WHERE device_id=? AND pinned=0 ORDER BY updated_at DESC LIMIT -1 OFFSET 100)`).run(deviceId);
      this.advanceChatCursor(deviceId);
    });
  }

  chatSnapshot(deviceId: string, sessionKey?: string): Record<string, unknown> {
    const agents = (this.db.prepare("SELECT id,name_enc FROM chat_agents WHERE device_id=? ORDER BY id").all(deviceId) as Array<{id:string;name_enc:string}>).map((row) => ({ id: row.id, name: decryptSecret(row.name_enc, this.masterKey) }));
    const sessions = (this.db.prepare("SELECT * FROM chat_sessions WHERE device_id=? ORDER BY pinned DESC,updated_at DESC LIMIT 100").all(deviceId) as Array<Record<string, unknown>>).map((row) => ({
      session_key: row.session_key, agent_id: row.agent_id, channel: row.channel, title: decryptSecret(String(row.title_enc), this.masterKey), updated_at: row.updated_at,
      archived: Boolean(row.archived), pinned: Boolean(row.pinned), hidden: Boolean(row.hidden), unread: Number(row.unread), run_status: row.run_status, run_id: row.run_id,
    }));
    const selected = sessionKey ?? String((sessions.find((item) => !item.hidden) as Record<string, unknown> | undefined)?.session_key ?? "");
    const messages = selected ? (this.db.prepare("SELECT * FROM chat_messages WHERE device_id=? AND session_key=? ORDER BY created_at LIMIT 500").all(deviceId, selected) as Array<Record<string, unknown>>).map((row) => ({
      id: row.id, session_key: row.session_key, role: row.role, status: row.status, body: decryptSecret(String(row.body_enc), this.masterKey), asset_id: row.asset_id,
      ...(row.asset_id ? { asset_url: `/v2/device/${deviceId}/assets/${row.asset_id}` } : {}), run_id: row.run_id, created_at: row.created_at,
    })) : [];
    const bridge = this.db.prepare("SELECT last_seen_at,last_error FROM chat_bridge_state WHERE device_id=?").get(deviceId) as Record<string, unknown> | undefined;
    const actions = selected ? (this.db.prepare("SELECT id,kind,status,attempts,detail,payload_enc,updated_at FROM chat_actions WHERE device_id=? ORDER BY updated_at DESC LIMIT 100").all(deviceId) as Array<Record<string, unknown>>)
      .flatMap((row) => {
        const action = JSON.parse(decryptSecret(String(row.payload_enc), this.masterKey)) as ChatAction;
        return action.session_key === selected ? [{ id: row.id, kind: row.kind, status: row.status, attempts: row.attempts, detail: row.detail, updated_at: row.updated_at, ...(action.kind === "send" || action.kind === "retry" ? { message_id: action.message_id } : {}) }] : [];
      }).slice(0, 25) : [];
    return { cursor: this.chatCursor(deviceId), agents, sessions, selected_session_key: selected || null, messages, actions, bridge: bridge ?? null };
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
    this.db.prepare("DELETE FROM audit_events WHERE created_at < datetime('now', '-30 days')").run();
  }

  newAssetPath(id: string): string { return join(this.assetsDir, `${id}.png`); }
}
