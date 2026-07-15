import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";
import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from "fastify";
import { cardInputSchema, cardPatchSchema, DEVICE_ID_PATTERN, devicePollQuerySchema, hashToken, issueToken, providerSchema } from "@paperboard/core";
import { z } from "zod";
import { requireAdmin, requireDevice, requireScope } from "./auth.js";
import type { RelayConfig } from "./config.js";
import { MAX_INPUT_BYTES, normalizeImage, SCREEN_HEIGHT, SCREEN_WIDTH } from "./images.js";
import { ProviderManager } from "./providers.js";
import { Store } from "./store.js";

const deviceParamSchema = z.object({ device: z.string().regex(DEVICE_ID_PATTERN) });
const cardParamSchema = deviceParamSchema.extend({ card: z.string().min(8).max(80) });
const assetParamSchema = deviceParamSchema.extend({ asset: z.string().min(8).max(80) });
const idemSchema = z.string().min(8).max(160);

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
      return status ?? reply.code(404).send({ error: "device not found" });
    } catch (error) { return bad(reply, error); }
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
    return { cursor: status.cursor, cards: store.activeCards(params.device, config.publicBaseUrl), server_time: new Date().toISOString() };
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
    const body = z.object({ id: z.string().regex(DEVICE_ID_PATTERN), scopes: z.array(z.enum(["cards:write", "cards:clear", "status:read"])).min(1) }).parse(request.body);
    const issued = issueToken("pb_client");
    store.createClient(body.id, issued.hash, [...new Set(body.scopes)]);
    return reply.code(201).send({ id: body.id, token: issued.token, scopes: body.scopes });
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
