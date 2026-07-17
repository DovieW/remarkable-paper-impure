import { EventEmitter } from "node:events";
import { createHash, randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";
import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from "fastify";
import { canvasEventInputSchema, canvasMessageInputSchema, canvasSessionInputSchema, cardInputSchema, cardPatchSchema, clientScopeSchema, commandResultSchema, DEVICE_ID_PATTERN, devicePollQuerySchema, hashToken, issueToken, paperboardCommandSchema, paperboardUiStateSchema, providerSchema, tabletLaunchSchema } from "@paperboard/core";
import { z } from "zod";
import { requireAdmin, requireDevice, requireScope } from "./auth.js";
import type { RelayConfig } from "./config.js";
import { MAX_INPUT_BYTES, normalizeImage, SCREEN_HEIGHT, SCREEN_WIDTH } from "./images.js";
import { ProviderManager } from "./providers.js";
import { Store } from "./store.js";
import { TabletBridge } from "./tablet.js";
import { fetchReaderPage } from "./reader.js";
import sharp from "sharp";

const deviceParamSchema = z.object({ device: z.string().regex(DEVICE_ID_PATTERN) });
const cardParamSchema = deviceParamSchema.extend({ card: z.string().min(8).max(80) });
const assetParamSchema = deviceParamSchema.extend({ asset: z.string().min(8).max(80) });
const idemSchema = z.string().min(8).max(160);
const sessionParamSchema = deviceParamSchema.extend({ session: z.string().min(8).max(80) });
const eventParamSchema = sessionParamSchema.extend({ event: z.string().min(8).max(80) });
const commandParamSchema = deviceParamSchema.extend({ command: z.string().min(8).max(80) });
const readerBookmarkSchema = z.object({
  url: z.string().url().max(2048).refine((value) => {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password && !url.port;
  }, "bookmark must be a credential-free public HTTPS URL"),
  title: z.string().trim().min(1).max(160),
});

function deny(reply: FastifyReply): FastifyReply { return reply.code(401).send({ error: "unauthorized" }); }
function bad(reply: FastifyReply, error: unknown): FastifyReply {
  return reply.code(400).send({ error: error instanceof Error ? error.message : "invalid request" });
}

function receipt(request: FastifyRequest, operation: string, value: Record<string, unknown> = {}): Record<string, unknown> {
  return { request_id: request.id, operation, accepted_at: new Date().toISOString(), ...value };
}

async function strokePreview(value: unknown): Promise<Buffer | undefined> {
  if (!value || typeof value !== "object" || !("strokes" in value) || !Array.isArray(value.strokes)) return undefined;
  const paths = value.strokes.flatMap((stroke) => {
    if (!stroke || typeof stroke !== "object" || !("points" in stroke) || !Array.isArray(stroke.points)) return [];
    const points = stroke.points.flatMap((point: unknown) => {
      if (!point || typeof point !== "object" || !("x" in point) || !("y" in point)) return [];
      return [`${Math.round(Number(point.x) * 1000)},${Math.round(Number(point.y) * 600)}`];
    });
    return points.length ? [`<polyline points="${points.join(" ")}" fill="none" stroke="#111" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>`] : [];
  });
  if (!paths.length) return undefined;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="600" viewBox="0 0 1000 600"><rect width="1000" height="600" fill="white"/>${paths.join("")}</svg>`;
  return sharp(Buffer.from(svg)).png().toBuffer();
}

export interface RelayServer {
  app: FastifyInstance;
  adminApp: FastifyInstance;
  store: Store;
  providers: ProviderManager;
}

export function buildServer(config: RelayConfig): RelayServer {
  const app = Fastify({ logger: true, bodyLimit: MAX_INPUT_BYTES });
  const adminApp = Fastify({ logger: true, bodyLimit: 1024 * 1024 });
  const store = new Store(config.databasePath, config.assetsDir);
  const providers = new ProviderManager(store, config.masterKey, config.publicBaseUrl);
  const tablet = new TabletBridge(config.tabletBridgeCommand);
  const changes = new EventEmitter();
  changes.setMaxListeners(1000);

  app.addContentTypeParser(["image/png", "image/jpeg", "image/bmp", "application/octet-stream"], { parseAs: "buffer" }, (_request, body, done) => done(null, body));
  app.setErrorHandler((error, _request, reply) => {
    const candidate = typeof error === "object" && error !== null && "statusCode" in error ? Number(error.statusCode) : undefined;
    const status = candidate && candidate < 500 ? candidate : error instanceof z.ZodError ? 400 : 500;
    if (status >= 500) app.log.error(error);
    reply.code(status).send({ error: status >= 500 ? "internal error" : error instanceof Error ? error.message : "invalid request" });
  });
  adminApp.setErrorHandler((error, _request, reply) => {
    const status = error instanceof z.ZodError ? 400 : 500;
    if (status >= 500) adminApp.log.error(error);
    reply.code(status).send({ error: status >= 500 ? "internal error" : error instanceof Error ? error.message : "invalid request" });
  });

  app.get("/healthz", async () => ({ status: "ok" }));

  function client(request: FastifyRequest, scope: string): { id: string } | undefined {
    if (!requireScope(request, store, scope)) return undefined;
    const token = request.headers.authorization!.slice(7).trim();
    return store.getClientByHash(hashToken(token));
  }

  function cardsWithDelivery(device: string): Array<Record<string, unknown>> {
    const status = store.status(device); const ui = store.getUiState(device);
    return store.listCards(device, config.publicBaseUrl).map((card) => ({ ...card,
      delivery: ui?.foreground && ui.visible_card_id === card.id ? "visible" :
        Number(status?.last_ack_cursor ?? 0) >= card.cursor ? "acknowledged" : "queued",
    }));
  }

  app.post("/v2/devices/:device/dashboard/assets", async (request, reply) => {
    const actor = client(request, "dashboard:write");
    if (!actor) return deny(reply);
    let params: z.infer<typeof deviceParamSchema>;
    try { params = deviceParamSchema.parse(request.params); } catch (error) { return bad(reply, error); }
    if (!store.getDevice(params.device)) return reply.code(404).send({ error: "device not found" });
    if (!Buffer.isBuffer(request.body)) return reply.code(415).send({ error: "send PNG, JPEG, or BMP bytes directly" });
    try {
      const normalized = await normalizeImage(request.body);
      const id = randomUUID().replaceAll("-", "");
      const path = store.newAssetPath(id);
      writeFileSync(path, normalized.png, { flag: "wx", mode: 0o600 });
      store.putAsset(params.device, id, path, normalized.sha256, new Date(Date.now() + 86_400_000).toISOString());
      return reply.code(201).send({ id, sha256: normalized.sha256, width: SCREEN_WIDTH, height: SCREEN_HEIGHT });
    } catch (error) { return bad(reply, error); }
  });

  app.post("/v2/devices/:device/dashboard/cards", async (request, reply) => {
    const actor = client(request, "dashboard:write");
    if (!actor) return deny(reply);
    let params: z.infer<typeof deviceParamSchema>;
    try { params = deviceParamSchema.parse(request.params); } catch (error) { return bad(reply, error); }
    const idem = request.headers["idempotency-key"];
    if (typeof idem === "string") {
      try { idemSchema.parse(idem); } catch (error) { return bad(reply, error); }
      const saved = store.idempotentResponse(actor.id, idem);
      if (saved) return reply.code(200).send(saved);
    }
    try {
      const input = cardInputSchema.parse(request.body);
      if (input.asset_id && !store.assetPath(params.device, input.asset_id)) return reply.code(400).send({ error: "asset does not belong to device or has expired" });
      const row = store.createCard(params.device, input);
      const response = receipt(request, "dashboard.card.create", { id: row.id, cursor: row.cursor, delivery: "queued" });
      if (typeof idem === "string") store.saveIdempotentResponse(actor.id, idem, response);
      store.audit(request.id, actor.id, "dashboard.card.create", params.device, "accepted", { card_id: row.id });
      changes.emit(params.device);
      return reply.code(201).send(response);
    } catch (error) { return bad(reply, error); }
  });

  app.patch("/v2/devices/:device/dashboard/cards/:card", async (request, reply) => {
    if (!client(request, "dashboard:write")) return deny(reply);
    try {
      const params = cardParamSchema.parse(request.params);
      const patch = cardPatchSchema.parse(request.body);
      const card = store.updateCard(params.device, params.card, patch);
      if (!card) return reply.code(404).send({ error: "card not found" });
      changes.emit(params.device);
      return { id: card.id, cursor: card.cursor };
    } catch (error) { return bad(reply, error); }
  });

  app.get("/v2/devices/:device/dashboard/cards", async (request, reply) => {
    if (!client(request, "dashboard:read")) return deny(reply);
    try { const { device } = deviceParamSchema.parse(request.params); return { cards: cardsWithDelivery(device) }; }
    catch (error) { return bad(reply, error); }
  });

  app.get("/v2/devices/:device/dashboard/cards/:card", async (request, reply) => {
    if (!client(request, "dashboard:read")) return deny(reply);
    try {
      const { device, card } = cardParamSchema.parse(request.params);
      const item = cardsWithDelivery(device).find((candidate) => candidate.id === card);
      return item ?? reply.code(404).send({ error: "card not found" });
    } catch (error) { return bad(reply, error); }
  });

  app.delete("/v2/devices/:device/dashboard/cards/:card", async (request, reply) => {
    if (!client(request, "dashboard:clear")) return deny(reply);
    try {
      const params = cardParamSchema.parse(request.params);
      if (!store.deleteCard(params.device, params.card)) return reply.code(404).send({ error: "card not found" });
      changes.emit(params.device);
      return reply.code(204).send();
    } catch (error) { return bad(reply, error); }
  });

  app.post("/v2/devices/:device/dashboard/clear", async (request, reply) => {
    if (!client(request, "dashboard:clear")) return deny(reply);
    try {
      const { device } = deviceParamSchema.parse(request.params);
      const removed = store.clearCards(device);
      changes.emit(device);
      return { removed };
    } catch (error) { return bad(reply, error); }
  });

  app.get("/v2/devices/:device/status", async (request, reply) => {
    if (!client(request, "status:read")) return deny(reply);
    try {
      const { device } = deviceParamSchema.parse(request.params);
      const status = store.status(device);
      if (!status) return reply.code(404).send({ error: "device not found" });
      const ui = store.getUiState(device);
      const cards = cardsWithDelivery(device);
      const visible = ui?.foreground && ui.visible_card_id ? cards.find((card) => card.id === ui.visible_card_id) : undefined;
      const lastSeenAt = Date.parse(status.last_seen_at ?? "");
      const online = Number.isFinite(lastSeenAt) && Date.now() - lastSeenAt <= 90_000;
      return { ...status, online, protocol_version: ui?.protocol_version ?? null,
        application: ui?.foreground ? ui.application : null, foreground: ui?.foreground ?? false,
        mode: ui?.mode ?? null,
        visible_card: visible ?? null, visible_index: ui?.visible_index ?? null, ambient_mode: ui?.ambient_mode ?? false,
        controls_visible: ui?.controls_visible ?? false, rendered_cursor: ui?.rendered_cursor ?? null,
        history_index: ui?.history_index ?? null, history_count: ui?.history_count ?? 0,
        scroll_offset: ui?.scroll_offset ?? 0, active_session_id: ui?.active_session_id ?? null,
        active_message_id: ui?.active_message_id ?? null, last_interaction_at: ui?.last_interaction_at ?? null,
        last_action: ui?.last_action ?? "", last_result: ui?.last_result ?? "", ui_updated_at: ui?.updated_at ?? null };
    } catch (error) { return bad(reply, error); }
  });

  app.get("/v2/devices/:device/apps", async (request, reply) => {
    if (!client(request, "device:apps")) return deny(reply);
    try { const { device } = deviceParamSchema.parse(request.params); return await tablet.apps(device); }
    catch (error) { return bad(reply, error); }
  });

  app.post("/v2/devices/:device/apps/launch", async (request, reply) => {
    if (!client(request, "device:control")) return deny(reply);
    try { const { device } = deviceParamSchema.parse(request.params); const { app_id } = tabletLaunchSchema.parse(request.body); return await tablet.launch(device, app_id); }
    catch (error) { return bad(reply, error); }
  });

  app.post("/v2/devices/:device/exit", async (request, reply) => {
    if (!client(request, "device:control")) return deny(reply);
    try { const { device } = deviceParamSchema.parse(request.params); return await tablet.return(device); }
    catch (error) { return bad(reply, error); }
  });

  app.get("/v2/devices/:device/screenshot", async (request, reply) => {
    if (!client(request, "screen:read")) return deny(reply);
    try {
      const { device } = deviceParamSchema.parse(request.params);
      const screenshot = await tablet.screenshot(device);
      return reply.type("image/png").header("cache-control", "no-store").send(screenshot);
    }
    catch (error) { return bad(reply, error); }
  });

  app.post("/v2/devices/:device/commands", async (request, reply) => {
    if (!client(request, "device:control")) return deny(reply);
    try {
      const { device } = deviceParamSchema.parse(request.params); const input = paperboardCommandSchema.parse(request.body);
      const ui = store.getUiState(device);
      if (!ui?.foreground || ui.application !== "paperboard") return reply.code(409).send({ error: "Paperboard is not foregrounded" });
      const command = store.createCommand(device, input.action); changes.emit(device);
      return reply.code(201).send(command);
    } catch (error) { return bad(reply, error); }
  });

  app.get("/v2/devices/:device/commands/:command", async (request, reply) => {
    if (!client(request, "device:control")) return deny(reply);
    try { const { device, command } = commandParamSchema.parse(request.params); return store.getCommand(device, command) ?? reply.code(404).send({ error: "command not found" }); }
    catch (error) { return bad(reply, error); }
  });

  app.post("/v2/devices/:device/screen/sessions", async (request, reply) => {
    if (!client(request, "screen:write")) return deny(reply);
    try { const { device } = deviceParamSchema.parse(request.params); const input = canvasSessionInputSchema.parse(request.body); const session = store.createCanvasSession(device, input.title); changes.emit(device); return reply.code(201).send(session); }
    catch (error) { return bad(reply, error); }
  });
  app.get("/v2/devices/:device/screen/sessions", async (request, reply) => {
    if (!client(request, "screen:read")) return deny(reply);
    try { const { device } = deviceParamSchema.parse(request.params); return { sessions: store.listCanvasSessions(device) }; } catch (error) { return bad(reply, error); }
  });
  app.get("/v2/devices/:device/screen/sessions/:session", async (request, reply) => {
    if (!client(request, "screen:read")) return deny(reply);
    try { const { device, session } = sessionParamSchema.parse(request.params); const item = store.getCanvasSession(device, session); return item ? { ...item, messages: store.canvasMessages(device, session, config.publicBaseUrl) } : reply.code(404).send({ error: "session not found" }); } catch (error) { return bad(reply, error); }
  });
  app.post("/v2/devices/:device/screen/sessions/:session/messages", async (request, reply) => {
    const actor = client(request, "screen:write");
    if (!actor) return deny(reply);
    try {
      const { device, session } = sessionParamSchema.parse(request.params);
      const input = canvasMessageInputSchema.parse(request.body);
      if (input.asset_id && !store.assetPath(device, input.asset_id)) return reply.code(400).send({ error: "asset does not belong to device or has expired" });
      const message = store.createCanvasMessage(device, session, input);
      if (!message) return reply.code(404).send({ error: "open session not found" });
      let launch: Record<string, unknown> | undefined;
      let command: Record<string, unknown> | undefined;
      if (input.foreground) {
        store.requestScreenPresentation(device, message.id);
        try { launch = await tablet.launch(device, "paperboard"); }
        catch { launch = { launched: false, status: "tablet-unavailable" }; }
        command = store.createCommand(device, "show_screen", message.id) as unknown as Record<string, unknown>;
      }
      changes.emit(device);
      store.audit(request.id, actor.id, "screen.message.present", device, "accepted", { session_id: session, message_id: message.id, foreground: input.foreground });
      return reply.code(201).send(receipt(request, "screen.message.present", { ...message, delivery: "queued", foreground_requested: input.foreground, launch, command }));
    } catch (error) { return bad(reply, error); }
  });

  /* One authenticated long-poll drives the unified Dashboard/Screen app. */
  app.get("/v2/device/:device/poll", async (request, reply) => {
    const { device } = deviceParamSchema.parse(request.params);
    if (!requireDevice(request, store, device)) return deny(reply);
    const query = devicePollQuerySchema.parse(request.query);
    const currentCursor = (): number => Number(store.status(device)?.cursor ?? 0) + store.canvasCursor(device);
    let cursor = currentCursor();
    if (cursor <= query.cursor && query.wait > 0) {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(done, query.wait * 1000);
        const changed = (): void => done();
        function done(): void { clearTimeout(timer); changes.off(device, changed); resolve(); }
        changes.once(device, changed);
      });
      cursor = currentCursor();
    }
    const session = store.latestOpenCanvasSession(device);
    const messages = store.canvasHistory(device, config.publicBaseUrl);
    store.heartbeat(device);
    return {
      protocol_version: 2,
      cursor,
      dashboard_cursor: Number(store.status(device)?.cursor ?? 0),
      screen_cursor: store.canvasCursor(device),
      cards: store.activeCards(device, config.publicBaseUrl),
      screen: { session: session ? { ...session, messages } : null, messages },
      presentation: { screen_message_id: store.screenPresentationTarget(device) },
      commands: store.pendingCommands(device),
      server_time: new Date().toISOString(),
    };
  });
  app.get("/v2/devices/:device/screen/sessions/:session/events", async (request, reply) => {
    if (!client(request, "screen:read")) return deny(reply);
    try { const { device, session } = sessionParamSchema.parse(request.params); const query = z.object({ after: z.coerce.number().int().min(0).default(0) }).parse(request.query); return { events: store.canvasEvents(device, session, query.after) }; } catch (error) { return bad(reply, error); }
  });
  app.post("/v2/devices/:device/screen/sessions/:session/events/:event/ack", async (request, reply) => {
    if (!client(request, "screen:write")) return deny(reply);
    try { const { device, session, event } = eventParamSchema.parse(request.params); return store.acknowledgeCanvasEvent(device, session, event) ? reply.code(204).send() : reply.code(404).send({ error: "event not found" }); } catch (error) { return bad(reply, error); }
  });
  app.post("/v2/devices/:device/screen/sessions/:session/close", async (request, reply) => {
    if (!client(request, "screen:write")) return deny(reply);
    try { const { device, session } = sessionParamSchema.parse(request.params); const closed = store.closeCanvasSession(device, session); if (closed) changes.emit(device); return closed ? { status: "closed" } : reply.code(404).send({ error: "session not found" }); } catch (error) { return bad(reply, error); }
  });

  app.get("/v2/device/:device/dashboard/poll", async (request, reply) => {
    const params = deviceParamSchema.parse(request.params);
    if (!requireDevice(request, store, params.device)) return deny(reply);
    const query = devicePollQuerySchema.parse(request.query);
    let status = store.status(params.device)!;
    if (status.cursor <= query.cursor && query.wait > 0) {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(done, query.wait * 1000);
        const changed = (): void => done();
        function done(): void { clearTimeout(timer); changes.off(params.device, changed); resolve(); }
        changes.once(params.device, changed);
      });
      status = store.status(params.device)!;
    }
    store.heartbeat(params.device);
    return { cursor: status.cursor, cards: store.activeCards(params.device, config.publicBaseUrl), commands: store.pendingCommands(params.device), server_time: new Date().toISOString() };
  });

  app.get("/v2/device/:device/screen/poll", async (request, reply) => {
    const { device } = deviceParamSchema.parse(request.params); if (!requireDevice(request, store, device)) return deny(reply);
    const query = devicePollQuerySchema.parse(request.query);
    let cursor = store.canvasCursor(device);
    if (cursor <= query.cursor && query.wait > 0) {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(done, query.wait * 1000); const changed = (): void => done();
        function done(): void { clearTimeout(timer); changes.off(device, changed); resolve(); }
        changes.once(device, changed);
      });
      cursor = store.canvasCursor(device);
    }
    const session = store.latestOpenCanvasSession(device);
    const messages = store.canvasHistory(device, config.publicBaseUrl);
    store.heartbeat(device);
    return { cursor, session: session ? { ...session, messages } : null, messages, server_time: new Date().toISOString() };
  });

  app.put("/v2/device/:device/ui-state", async (request, reply) => {
    const { device } = deviceParamSchema.parse(request.params); if (!requireDevice(request, store, device)) return deny(reply);
    try { store.putUiState(device, paperboardUiStateSchema.parse(request.body)); return reply.code(204).send(); } catch (error) { return bad(reply, error); }
  });

  app.post("/v2/device/:device/commands/:command/result", async (request, reply) => {
    const { device, command } = commandParamSchema.parse(request.params); if (!requireDevice(request, store, device)) return deny(reply);
    try { const result = commandResultSchema.parse({ ...(request.body as object), id: command }); return store.finishCommand(device, command, result.status, result.detail) ? reply.code(204).send() : reply.code(404).send({ error: "command not found" }); } catch (error) { return bad(reply, error); }
  });

  app.post("/v2/device/:device/screen/sessions/:session/events", async (request, reply) => {
    const { device, session } = sessionParamSchema.parse(request.params); if (!requireDevice(request, store, device)) return deny(reply);
    try {
      const input = canvasEventInputSchema.parse(request.body);
      const preview = await strokePreview(input.value);
      if (preview && typeof input.value === "object" && input.value && "strokes" in input.value) {
        const id = randomUUID().replaceAll("-", "");
        const path = store.newAssetPath(id);
        writeFileSync(path, preview, { flag: "wx", mode: 0o600 });
        store.putAsset(device, id, path, createHash("sha256").update(preview).digest("hex"), new Date(Date.now() + 86_400_000).toISOString());
        input.value.preview_asset_id = id;
      }
      const event = store.createCanvasEvent(device, session, input);
      return event ? reply.code(201).send(event) : reply.code(404).send({ error: "session or message not found" });
    } catch (error) { return bad(reply, error); }
  });

  app.post("/v2/device/:device/reader", async (request, reply) => {
    const { device } = deviceParamSchema.parse(request.params); if (!requireDevice(request, store, device)) return deny(reply);
    try {
      const body = z.object({ input: z.string().trim().min(1).max(2048).optional(), url: z.string().trim().min(1).max(2048).optional() })
        .refine((item) => Boolean(item.input || item.url), "reader input is required").parse(request.body);
      const page = await fetchReaderPage(body.input ?? body.url!);
      return { ...page, bookmarked: store.isReaderBookmark(device, page.url), bookmarks: store.readerBookmarks(device) };
    } catch (error) { return bad(reply, error); }
  });

  app.get("/v2/device/:device/reader/bookmarks", async (request, reply) => {
    const { device } = deviceParamSchema.parse(request.params); if (!requireDevice(request, store, device)) return deny(reply);
    return { bookmarks: store.readerBookmarks(device) };
  });

  app.post("/v2/device/:device/reader/bookmarks", async (request, reply) => {
    const { device } = deviceParamSchema.parse(request.params); if (!requireDevice(request, store, device)) return deny(reply);
    try {
      const bookmark = readerBookmarkSchema.parse(request.body);
      return store.toggleReaderBookmark(device, bookmark.url, bookmark.title);
    } catch (error) { return bad(reply, error); }
  });

  app.post("/v2/device/:device/ack", async (request, reply) => {
    const params = deviceParamSchema.parse(request.params);
    if (!requireDevice(request, store, params.device)) return deny(reply);
    const body = z.object({ cursor: z.number().int().min(0) }).parse(request.body);
    store.heartbeat(params.device, body.cursor);
    return reply.code(204).send();
  });

  app.post("/v2/device/:device/heartbeat", async (request, reply) => {
    const params = deviceParamSchema.parse(request.params);
    if (!requireDevice(request, store, params.device)) return deny(reply);
    store.heartbeat(params.device);
    return reply.code(204).send();
  });

  app.post("/v2/device/:device/dashboard/cards/:card/dismiss", async (request, reply) => {
    const params = cardParamSchema.parse(request.params);
    if (!requireDevice(request, store, params.device)) return deny(reply);
    if (!store.deleteCard(params.device, params.card)) return reply.code(404).send({ error: "card not found" });
    changes.emit(params.device);
    return reply.code(204).send();
  });

  app.post("/v2/device/:device/dashboard/cards/:card/pin", async (request, reply) => {
    const params = cardParamSchema.parse(request.params);
    if (!requireDevice(request, store, params.device)) return deny(reply);
    const card = store.getCard(params.device, params.card);
    if (!card) return reply.code(404).send({ error: "card not found" });
    const updated = store.updateCard(params.device, params.card, { pinned: !Boolean(card.pinned) })!;
    changes.emit(params.device);
    return { id: updated.id, pinned: Boolean(updated.pinned), cursor: updated.cursor };
  });

  app.get("/v2/device/:device/assets/:asset", async (request, reply) => {
    const params = assetParamSchema.parse(request.params);
    if (!requireDevice(request, store, params.device)) return deny(reply);
    const path = store.assetPath(params.device, params.asset);
    if (!path) return reply.code(404).send({ error: "asset not found" });
    const { readFile } = await import("node:fs/promises");
    return reply.type("image/png").header("cache-control", "private, max-age=300").send(await readFile(path));
  });

  adminApp.get("/healthz", async () => ({ status: "ok", listener: "admin-local" }));

  adminApp.post("/admin/devices", async (request, reply) => {
    if (!requireAdmin(request, config.adminToken)) return deny(reply);
    const body = z.object({ id: z.string().regex(DEVICE_ID_PATTERN) }).parse(request.body);
    const issued = issueToken("pb_device");
    store.createDevice(body.id, issued.hash);
    return reply.code(201).send({ id: body.id, token: issued.token });
  });

  adminApp.post("/admin/clients", async (request, reply) => {
    if (!requireAdmin(request, config.adminToken)) return deny(reply);
    const body = z.object({ id: z.string().regex(DEVICE_ID_PATTERN), scopes: z.array(clientScopeSchema).min(1) }).parse(request.body);
    const issued = issueToken("pb_client");
    store.createClient(body.id, issued.hash, [...new Set(body.scopes)]);
    return reply.code(201).send({ id: body.id, token: issued.token, scopes: body.scopes });
  });
  adminApp.put("/admin/clients/:client/scopes", async (request, reply) => {
    if (!requireAdmin(request, config.adminToken)) return deny(reply);
    const params = z.object({ client: z.string().regex(DEVICE_ID_PATTERN) }).parse(request.params);
    const body = z.object({ scopes: z.array(clientScopeSchema).min(1) }).parse(request.body);
    return store.updateClientScopes(params.client, [...new Set(body.scopes)]) ? { id: params.client, scopes: body.scopes } : reply.code(404).send({ error: "client not found" });
  });

  adminApp.get("/admin/clients", async (request, reply) => {
    if (!requireAdmin(request, config.adminToken)) return deny(reply);
    return { clients: store.listClients() };
  });

  adminApp.delete("/admin/clients/:client", async (request, reply) => {
    if (!requireAdmin(request, config.adminToken)) return deny(reply);
    const { client } = z.object({ client: z.string().regex(DEVICE_ID_PATTERN) }).parse(request.params);
    return store.revokeClient(client) ? receipt(request, "admin.client.revoke", { id: client, revoked: true }) : reply.code(404).send({ error: "active client not found" });
  });

  adminApp.get("/admin/migrations", async (request, reply) => {
    if (!requireAdmin(request, config.adminToken)) return deny(reply);
    return { migrations: store.migrationStatus() };
  });

  adminApp.post("/admin/devices/:device/token", async (request, reply) => {
    if (!requireAdmin(request, config.adminToken)) return deny(reply);
    const { device } = deviceParamSchema.parse(request.params);
    const issued = issueToken("pb_device");
    if (!store.rotateDeviceToken(device, issued.hash)) return reply.code(404).send({ error: "device not found" });
    return { id: device, token: issued.token };
  });

  adminApp.put("/admin/devices/:device/provider", async (request, reply) => {
    if (!requireAdmin(request, config.adminToken)) return deny(reply);
    const { device } = deviceParamSchema.parse(request.params);
    const provider = providerSchema.parse(request.body);
    if (!providers.set(device, provider)) return reply.code(404).send({ error: "device not found" });
    changes.emit(device);
    return { device, provider: provider.kind };
  });

  const cleanup = setInterval(() => store.cleanup(), 60_000);
  cleanup.unref();
  app.addHook("onClose", async () => { clearInterval(cleanup); providers.stop(); store.close(); });
  return { app, adminApp, store, providers };
}
