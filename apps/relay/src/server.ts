import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
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

const deviceParamSchema = z.object({ device: z.string().regex(DEVICE_ID_PATTERN) });
const cardParamSchema = deviceParamSchema.extend({ card: z.string().min(8).max(80) });
const assetParamSchema = deviceParamSchema.extend({ asset: z.string().min(8).max(80) });
const idemSchema = z.string().min(8).max(160);
const sessionParamSchema = deviceParamSchema.extend({ session: z.string().min(8).max(80) });
const eventParamSchema = sessionParamSchema.extend({ event: z.string().min(8).max(80) });
const commandParamSchema = deviceParamSchema.extend({ command: z.string().min(8).max(80) });

function deny(reply: FastifyReply): FastifyReply { return reply.code(401).send({ error: "unauthorized" }); }
function bad(reply: FastifyReply, error: unknown): FastifyReply {
  return reply.code(400).send({ error: error instanceof Error ? error.message : "invalid request" });
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

  app.post("/v1/devices/:device/assets", async (request, reply) => {
    const actor = client(request, "cards:write");
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

  app.post("/v1/devices/:device/cards", async (request, reply) => {
    const actor = client(request, "cards:write");
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
      const response = { id: row.id, cursor: row.cursor };
      if (typeof idem === "string") store.saveIdempotentResponse(actor.id, idem, response);
      changes.emit(params.device);
      return reply.code(201).send(response);
    } catch (error) { return bad(reply, error); }
  });

  app.patch("/v1/devices/:device/cards/:card", async (request, reply) => {
    if (!client(request, "cards:write")) return deny(reply);
    try {
      const params = cardParamSchema.parse(request.params);
      const patch = cardPatchSchema.parse(request.body);
      const card = store.updateCard(params.device, params.card, patch);
      if (!card) return reply.code(404).send({ error: "card not found" });
      changes.emit(params.device);
      return { id: card.id, cursor: card.cursor };
    } catch (error) { return bad(reply, error); }
  });

  app.get("/v1/devices/:device/cards", async (request, reply) => {
    if (!client(request, "cards:read")) return deny(reply);
    try { const { device } = deviceParamSchema.parse(request.params); return { cards: cardsWithDelivery(device) }; }
    catch (error) { return bad(reply, error); }
  });

  app.get("/v1/devices/:device/cards/:card", async (request, reply) => {
    if (!client(request, "cards:read")) return deny(reply);
    try {
      const { device, card } = cardParamSchema.parse(request.params);
      const item = cardsWithDelivery(device).find((candidate) => candidate.id === card);
      return item ?? reply.code(404).send({ error: "card not found" });
    } catch (error) { return bad(reply, error); }
  });

  app.delete("/v1/devices/:device/cards/:card", async (request, reply) => {
    if (!client(request, "cards:clear")) return deny(reply);
    try {
      const params = cardParamSchema.parse(request.params);
      if (!store.deleteCard(params.device, params.card)) return reply.code(404).send({ error: "card not found" });
      changes.emit(params.device);
      return reply.code(204).send();
    } catch (error) { return bad(reply, error); }
  });

  app.post("/v1/devices/:device/clear", async (request, reply) => {
    if (!client(request, "cards:clear")) return deny(reply);
    try {
      const { device } = deviceParamSchema.parse(request.params);
      const removed = store.clearCards(device);
      changes.emit(device);
      return { removed };
    } catch (error) { return bad(reply, error); }
  });

  app.get("/v1/devices/:device/status", async (request, reply) => {
    if (!client(request, "status:read")) return deny(reply);
    try {
      const { device } = deviceParamSchema.parse(request.params);
      const status = store.status(device);
      if (!status) return reply.code(404).send({ error: "device not found" });
      const ui = store.getUiState(device);
      const cards = cardsWithDelivery(device);
      const visible = ui?.foreground && ui.visible_card_id ? cards.find((card) => card.id === ui.visible_card_id) : undefined;
      return { ...status, application: ui?.foreground ? ui.application : null, foreground: ui?.foreground ?? false,
        visible_card: visible ?? null, visible_index: ui?.visible_index ?? null, ambient_mode: ui?.ambient_mode ?? false,
        controls_visible: ui?.controls_visible ?? false, rendered_cursor: ui?.rendered_cursor ?? null,
        last_action: ui?.last_action ?? "", last_result: ui?.last_result ?? "", ui_updated_at: ui?.updated_at ?? null };
    } catch (error) { return bad(reply, error); }
  });

  app.get("/v1/devices/:device/tablet/status", async (request, reply) => {
    if (!client(request, "status:read")) return deny(reply);
    try { const { device } = deviceParamSchema.parse(request.params); return await tablet.status(device); }
    catch (error) { return bad(reply, error); }
  });

  app.get("/v1/devices/:device/tablet/apps", async (request, reply) => {
    if (!client(request, "device:apps")) return deny(reply);
    try { const { device } = deviceParamSchema.parse(request.params); return await tablet.apps(device); }
    catch (error) { return bad(reply, error); }
  });

  app.post("/v1/devices/:device/tablet/launch", async (request, reply) => {
    if (!client(request, "device:control")) return deny(reply);
    try { const { device } = deviceParamSchema.parse(request.params); const { app_id } = tabletLaunchSchema.parse(request.body); return await tablet.launch(device, app_id); }
    catch (error) { return bad(reply, error); }
  });

  app.post("/v1/devices/:device/tablet/return", async (request, reply) => {
    if (!client(request, "device:control")) return deny(reply);
    try { const { device } = deviceParamSchema.parse(request.params); return await tablet.return(device); }
    catch (error) { return bad(reply, error); }
  });

  app.get("/v1/devices/:device/tablet/screenshot", async (request, reply) => {
    if (!client(request, "screen:read")) return deny(reply);
    try { const { device } = deviceParamSchema.parse(request.params); return reply.type("image/png").header("cache-control", "no-store").send(await tablet.screenshot(device)); }
    catch (error) { return bad(reply, error); }
  });

  app.post("/v1/devices/:device/commands", async (request, reply) => {
    if (!client(request, "paperboard:control")) return deny(reply);
    try {
      const { device } = deviceParamSchema.parse(request.params); const input = paperboardCommandSchema.parse(request.body);
      const ui = store.getUiState(device);
      if (!ui?.foreground || ui.application !== "paperboard") return reply.code(409).send({ error: "Paperboard is not foregrounded" });
      const command = store.createCommand(device, input.action); changes.emit(device);
      return reply.code(201).send(command);
    } catch (error) { return bad(reply, error); }
  });

  app.get("/v1/devices/:device/commands/:command", async (request, reply) => {
    if (!client(request, "paperboard:control")) return deny(reply);
    try { const { device, command } = commandParamSchema.parse(request.params); return store.getCommand(device, command) ?? reply.code(404).send({ error: "command not found" }); }
    catch (error) { return bad(reply, error); }
  });

  app.post("/v1/devices/:device/canvas/sessions", async (request, reply) => {
    if (!client(request, "canvas:write")) return deny(reply);
    try { const { device } = deviceParamSchema.parse(request.params); const input = canvasSessionInputSchema.parse(request.body); const session = store.createCanvasSession(device, input.title); changes.emit(device); return reply.code(201).send(session); }
    catch (error) { return bad(reply, error); }
  });
  app.get("/v1/devices/:device/canvas/sessions", async (request, reply) => {
    if (!client(request, "canvas:read")) return deny(reply);
    try { const { device } = deviceParamSchema.parse(request.params); return { sessions: store.listCanvasSessions(device) }; } catch (error) { return bad(reply, error); }
  });
  app.get("/v1/devices/:device/canvas/sessions/:session", async (request, reply) => {
    if (!client(request, "canvas:read")) return deny(reply);
    try { const { device, session } = sessionParamSchema.parse(request.params); const item = store.getCanvasSession(device, session); return item ? { ...item, messages: store.canvasMessages(device, session, config.publicBaseUrl) } : reply.code(404).send({ error: "session not found" }); } catch (error) { return bad(reply, error); }
  });
  app.post("/v1/devices/:device/canvas/sessions/:session/messages", async (request, reply) => {
    if (!client(request, "canvas:write")) return deny(reply);
    try { const { device, session } = sessionParamSchema.parse(request.params); const input = canvasMessageInputSchema.parse(request.body); if (input.asset_id && !store.assetPath(device, input.asset_id)) return reply.code(400).send({ error: "asset does not belong to device or has expired" }); const message = store.createCanvasMessage(device, session, input); if (message) changes.emit(device); return message ? reply.code(201).send(message) : reply.code(404).send({ error: "open session not found" }); } catch (error) { return bad(reply, error); }
  });
  app.get("/v1/devices/:device/canvas/sessions/:session/events", async (request, reply) => {
    if (!client(request, "canvas:read")) return deny(reply);
    try { const { device, session } = sessionParamSchema.parse(request.params); const query = z.object({ after: z.coerce.number().int().min(0).default(0) }).parse(request.query); return { events: store.canvasEvents(device, session, query.after) }; } catch (error) { return bad(reply, error); }
  });
  app.post("/v1/devices/:device/canvas/sessions/:session/events/:event/ack", async (request, reply) => {
    if (!client(request, "canvas:write")) return deny(reply);
    try { const { device, session, event } = eventParamSchema.parse(request.params); return store.acknowledgeCanvasEvent(device, session, event) ? reply.code(204).send() : reply.code(404).send({ error: "event not found" }); } catch (error) { return bad(reply, error); }
  });
  app.post("/v1/devices/:device/canvas/sessions/:session/close", async (request, reply) => {
    if (!client(request, "canvas:write")) return deny(reply);
    try { const { device, session } = sessionParamSchema.parse(request.params); const closed = store.closeCanvasSession(device, session); if (closed) changes.emit(device); return closed ? { status: "closed" } : reply.code(404).send({ error: "session not found" }); } catch (error) { return bad(reply, error); }
  });

  app.get("/v1/device/:device/poll", async (request, reply) => {
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

  app.get("/v1/device/:device/canvas/poll", async (request, reply) => {
    const { device } = deviceParamSchema.parse(request.params); if (!requireDevice(request, store, device)) return deny(reply);
    const query = devicePollQuerySchema.parse(request.query);
    let session = store.latestOpenCanvasSession(device);
    if ((!session || session.cursor <= query.cursor) && query.wait > 0) {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(done, query.wait * 1000); const changed = (): void => done();
        function done(): void { clearTimeout(timer); changes.off(device, changed); resolve(); }
        changes.once(device, changed);
      });
      session = store.latestOpenCanvasSession(device);
    }
    store.heartbeat(device);
    return { cursor: session?.cursor ?? 0, session: session ? { ...session, messages: store.canvasMessages(device, session.id, config.publicBaseUrl) } : null, server_time: new Date().toISOString() };
  });

  app.put("/v1/device/:device/ui-state", async (request, reply) => {
    const { device } = deviceParamSchema.parse(request.params); if (!requireDevice(request, store, device)) return deny(reply);
    try { store.putUiState(device, paperboardUiStateSchema.parse(request.body)); return reply.code(204).send(); } catch (error) { return bad(reply, error); }
  });

  app.post("/v1/device/:device/commands/:command/result", async (request, reply) => {
    const { device, command } = commandParamSchema.parse(request.params); if (!requireDevice(request, store, device)) return deny(reply);
    try { const result = commandResultSchema.parse({ ...(request.body as object), id: command }); return store.finishCommand(device, command, result.status, result.detail) ? reply.code(204).send() : reply.code(404).send({ error: "command not found" }); } catch (error) { return bad(reply, error); }
  });

  app.post("/v1/device/:device/canvas/sessions/:session/events", async (request, reply) => {
    const { device, session } = sessionParamSchema.parse(request.params); if (!requireDevice(request, store, device)) return deny(reply);
    try { const event = store.createCanvasEvent(device, session, canvasEventInputSchema.parse(request.body)); return event ? reply.code(201).send(event) : reply.code(404).send({ error: "session or message not found" }); } catch (error) { return bad(reply, error); }
  });

  app.post("/v1/device/:device/ack", async (request, reply) => {
    const params = deviceParamSchema.parse(request.params);
    if (!requireDevice(request, store, params.device)) return deny(reply);
    const body = z.object({ cursor: z.number().int().min(0) }).parse(request.body);
    store.heartbeat(params.device, body.cursor);
    return reply.code(204).send();
  });

  app.post("/v1/device/:device/heartbeat", async (request, reply) => {
    const params = deviceParamSchema.parse(request.params);
    if (!requireDevice(request, store, params.device)) return deny(reply);
    store.heartbeat(params.device);
    return reply.code(204).send();
  });

  app.post("/v1/device/:device/cards/:card/dismiss", async (request, reply) => {
    const params = cardParamSchema.parse(request.params);
    if (!requireDevice(request, store, params.device)) return deny(reply);
    if (!store.deleteCard(params.device, params.card)) return reply.code(404).send({ error: "card not found" });
    changes.emit(params.device);
    return reply.code(204).send();
  });

  app.post("/v1/device/:device/cards/:card/pin", async (request, reply) => {
    const params = cardParamSchema.parse(request.params);
    if (!requireDevice(request, store, params.device)) return deny(reply);
    const card = store.getCard(params.device, params.card);
    if (!card) return reply.code(404).send({ error: "card not found" });
    const updated = store.updateCard(params.device, params.card, { pinned: !Boolean(card.pinned) })!;
    changes.emit(params.device);
    return { id: updated.id, pinned: Boolean(updated.pinned), cursor: updated.cursor };
  });

  app.get("/v1/device/:device/assets/:asset", async (request, reply) => {
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
