import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import sharp from "sharp";
import { buildServer } from "../src/server.js";
import type { RelayConfig } from "../src/config.js";

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "paperboard-test-"));
  const config: RelayConfig = {
    host: "127.0.0.1", port: 0, adminHost: "127.0.0.1", adminPort: 0, dataDir: root, databasePath: join(root, "test.sqlite"),
    assetsDir: join(root, "assets"), masterKey: Buffer.alloc(32, 9), adminToken: "admin-test-token-with-enough-entropy",
    publicBaseUrl: "https://paperboard.example",
  };
  const server = buildServer(config);
  return { ...server, config, root };
}

async function provision(adminApp: ReturnType<typeof buildServer>["adminApp"], adminToken: string, device = "pure-one") {
  const deviceResponse = await adminApp.inject({ method: "POST", url: "/admin/devices", headers: { authorization: `Bearer ${adminToken}` }, payload: { id: device } });
  assert.equal(deviceResponse.statusCode, 201);
  const clientResponse = await adminApp.inject({ method: "POST", url: "/admin/clients", headers: { authorization: `Bearer ${adminToken}` }, payload: { id: `agent-${device}`, scopes: ["cards:read", "cards:write", "cards:clear", "status:read", "paperboard:control", "canvas:read", "canvas:write"] } });
  assert.equal(clientResponse.statusCode, 201);
  return { deviceToken: deviceResponse.json().token as string, clientToken: clientResponse.json().token as string };
}

test("card lifecycle is authenticated, idempotent, ordered, and isolated", async (context) => {
  const current = fixture();
  context.after(async () => { await current.adminApp.close(); await current.app.close(); rmSync(current.root, { recursive: true, force: true }); });
  const first = await provision(current.adminApp, current.config.adminToken);
  const second = await provision(current.adminApp, current.config.adminToken, "pure-two");
  const unauthorized = await current.app.inject({ method: "GET", url: "/v1/devices/pure-one/status" });
  assert.equal(unauthorized.statusCode, 401);

  const payload = { title: "Build complete", body: "All checks passed", kind: "message", priority: "urgent", ttl_seconds: 300, pinned: false };
  const headers = { authorization: `Bearer ${first.clientToken}`, "idempotency-key": "stable-request-0001" };
  const created = await current.app.inject({ method: "POST", url: "/v1/devices/pure-one/cards", headers, payload });
  const repeated = await current.app.inject({ method: "POST", url: "/v1/devices/pure-one/cards", headers, payload });
  assert.equal(created.statusCode, 201);
  assert.equal(repeated.statusCode, 200);
  assert.deepEqual(repeated.json(), created.json());

  const poll = await current.app.inject({ method: "GET", url: "/v1/device/pure-one/poll?cursor=0&wait=0", headers: { authorization: `Bearer ${first.deviceToken}` } });
  assert.equal(poll.statusCode, 200);
  assert.equal(poll.json().cards.length, 1);
  assert.equal(poll.json().cards[0].title, "Build complete");
  const otherPoll = await current.app.inject({ method: "GET", url: "/v1/device/pure-two/poll?cursor=0&wait=0", headers: { authorization: `Bearer ${second.deviceToken}` } });
  assert.equal(otherPoll.json().cards.length, 0);

  const ack = await current.app.inject({ method: "POST", url: "/v1/device/pure-one/ack", headers: { authorization: `Bearer ${first.deviceToken}` }, payload: { cursor: poll.json().cursor } });
  assert.equal(ack.statusCode, 204);
  const status = await current.app.inject({ method: "GET", url: "/v1/devices/pure-one/status", headers: { authorization: `Bearer ${first.clientToken}` } });
  assert.equal(status.json().last_ack_cursor, poll.json().cursor);
});

test("normalizes uploaded images and protects assets with the device token", async (context) => {
  const current = fixture();
  context.after(async () => { await current.adminApp.close(); await current.app.close(); rmSync(current.root, { recursive: true, force: true }); });
  const credentials = await provision(current.adminApp, current.config.adminToken);
  const source = await sharp({ create: { width: 64, height: 32, channels: 3, background: "#cc3344" } }).jpeg().toBuffer();
  const uploaded = await current.app.inject({ method: "POST", url: "/v1/devices/pure-one/assets", headers: { authorization: `Bearer ${credentials.clientToken}`, "content-type": "image/jpeg" }, payload: source });
  assert.equal(uploaded.statusCode, 201);
  const assetId = uploaded.json().id as string;
  const denied = await current.app.inject({ method: "GET", url: `/v1/device/pure-one/assets/${assetId}` });
  assert.equal(denied.statusCode, 401);
  const fetched = await current.app.inject({ method: "GET", url: `/v1/device/pure-one/assets/${assetId}`, headers: { authorization: `Bearer ${credentials.deviceToken}` } });
  assert.equal(fetched.statusCode, 200);
  assert.equal(fetched.headers["content-type"], "image/png");
  const metadata = await sharp(fetched.rawPayload).metadata();
  assert.equal(uploaded.json().width, 1872);
  assert.equal(uploaded.json().height, 1404);
  assert.equal(metadata.width, 1872);
  assert.equal(metadata.height, 1404);
});

test("provider credentials are encrypted at rest and only one provider is active", async (context) => {
  const current = fixture();
  context.after(async () => { await current.adminApp.close(); await current.app.close(); rmSync(current.root, { recursive: true, force: true }); });
  await provision(current.adminApp, current.config.adminToken);
  const response = await current.adminApp.inject({ method: "PUT", url: "/admin/devices/pure-one/provider", headers: { authorization: `Bearer ${current.config.adminToken}` }, payload: { kind: "trmnl-hosted", base_url: "https://trmnl.example", device_id: "upstream-one", access_token: "super-secret-upstream-token" } });
  assert.equal(response.statusCode, 200);
  const row = current.store.getProvider("pure-one")!;
  assert.equal(row.kind, "trmnl-hosted");
  assert.ok(row.encryptedConfig);
  assert.equal(row.encryptedConfig!.includes("super-secret-upstream-token"), false);
});

test("priority ordering and tablet pin/dismiss actions advance the device cursor", async (context) => {
  const current = fixture();
  context.after(async () => { await current.adminApp.close(); await current.app.close(); rmSync(current.root, { recursive: true, force: true }); });
  const credentials = await provision(current.adminApp, current.config.adminToken);
  const clientHeaders = { authorization: `Bearer ${credentials.clientToken}` };
  const deviceHeaders = { authorization: `Bearer ${credentials.deviceToken}` };
  const create = async (title: string, priority: "ambient" | "normal" | "urgent", pinned = false) => {
    const response = await current.app.inject({ method: "POST", url: "/v1/devices/pure-one/cards", headers: clientHeaders,
      payload: { kind: "message", title, body: "", priority, ttl_seconds: 300, pinned } });
    assert.equal(response.statusCode, 201);
    return response.json().id as string;
  };
  await create("ambient", "ambient");
  const normal = await create("normal", "normal");
  await create("pinned", "normal", true);
  await create("urgent", "urgent");

  const firstPoll = await current.app.inject({ method: "GET", url: "/v1/device/pure-one/poll?cursor=0&wait=0", headers: deviceHeaders });
  assert.deepEqual(firstPoll.json().cards.map((card: { title: string }) => card.title), ["urgent", "pinned", "normal", "ambient"]);
  const before = firstPoll.json().cursor as number;
  const pin = await current.app.inject({ method: "POST", url: `/v1/device/pure-one/cards/${normal}/pin`, headers: deviceHeaders });
  assert.equal(pin.statusCode, 200);
  assert.equal(pin.json().pinned, true);
  assert.ok(pin.json().cursor > before);
  const dismiss = await current.app.inject({ method: "POST", url: `/v1/device/pure-one/cards/${normal}/dismiss`, headers: deviceHeaders });
  assert.equal(dismiss.statusCode, 204);
  const secondPoll = await current.app.inject({ method: "GET", url: `/v1/device/pure-one/poll?cursor=${pin.json().cursor}&wait=0`, headers: deviceHeaders });
  assert.equal(secondPoll.json().cards.some((card: { id: string }) => card.id === normal), false);

  const adminOnPublicListener = await current.app.inject({ method: "POST", url: "/admin/devices", headers: { authorization: `Bearer ${current.config.adminToken}` }, payload: { id: "must-not-exist" } });
  assert.equal(adminOnPublicListener.statusCode, 404);
});

test("reports visible state and executes only fresh foreground commands", async (context) => {
  const current = fixture();
  context.after(async () => { await current.adminApp.close(); await current.app.close(); rmSync(current.root, { recursive: true, force: true }); });
  const credentials = await provision(current.adminApp, current.config.adminToken);
  const clientHeaders = { authorization: `Bearer ${credentials.clientToken}` };
  const deviceHeaders = { authorization: `Bearer ${credentials.deviceToken}` };
  const created = await current.app.inject({ method: "POST", url: "/v1/devices/pure-one/cards", headers: clientHeaders, payload: { kind: "message", title: "Visible", body: "Now", ttl_seconds: 300, priority: "normal", pinned: false } });
  const card = created.json().id as string;
  const denied = await current.app.inject({ method: "POST", url: "/v1/devices/pure-one/commands", headers: clientHeaders, payload: { action: "next" } });
  assert.equal(denied.statusCode, 409);
  const state = await current.app.inject({ method: "PUT", url: "/v1/device/pure-one/ui-state", headers: deviceHeaders, payload: { application: "paperboard", foreground: true, rendered_cursor: created.json().cursor, visible_card_id: card, visible_index: 0, card_count: 1, ambient_mode: false, controls_visible: false, last_action: "open", last_result: "visible" } });
  assert.equal(state.statusCode, 204);
  const status = await current.app.inject({ method: "GET", url: "/v1/devices/pure-one/status", headers: clientHeaders });
  assert.equal(status.json().foreground, true);
  assert.equal(status.json().visible_card.id, card);
  const command = await current.app.inject({ method: "POST", url: "/v1/devices/pure-one/commands", headers: clientHeaders, payload: { action: "next" } });
  assert.equal(command.statusCode, 201);
  const poll = await current.app.inject({ method: "GET", url: `/v1/device/pure-one/poll?cursor=${created.json().cursor}&wait=0`, headers: deviceHeaders });
  assert.equal(poll.json().commands[0].action, "next");
  const completed = await current.app.inject({ method: "POST", url: `/v1/device/pure-one/commands/${command.json().id}/result`, headers: deviceHeaders, payload: { status: "completed", detail: "only card" } });
  assert.equal(completed.statusCode, 204);
  const result = await current.app.inject({ method: "GET", url: `/v1/devices/pure-one/commands/${command.json().id}`, headers: clientHeaders });
  assert.equal(result.json().status, "completed");
});

test("Canvas sessions carry structured messages and acknowledged events", async (context) => {
  const current = fixture();
  context.after(async () => { await current.adminApp.close(); await current.app.close(); rmSync(current.root, { recursive: true, force: true }); });
  const credentials = await provision(current.adminApp, current.config.adminToken);
  const clientHeaders = { authorization: `Bearer ${credentials.clientToken}` };
  const deviceHeaders = { authorization: `Bearer ${credentials.deviceToken}` };
  const session = await current.app.inject({ method: "POST", url: "/v1/devices/pure-one/canvas/sessions", headers: clientHeaders, payload: { title: "Dinner" } });
  assert.equal(session.statusCode, 201);
  const sessionId = session.json().id as string;
  const message = await current.app.inject({ method: "POST", url: `/v1/devices/pure-one/canvas/sessions/${sessionId}/messages`, headers: clientHeaders, payload: { title: "Choose", body: "Dinner", actions: [{ type: "choice", id: "pizza123", label: "Pizza" }] } });
  assert.equal(message.statusCode, 201);
  const tabletPoll = await current.app.inject({ method: "GET", url: "/v1/device/pure-one/canvas/poll?cursor=0&wait=0", headers: deviceHeaders });
  assert.equal(tabletPoll.statusCode, 200);
  assert.equal(tabletPoll.json().session.id, sessionId);
  assert.equal(tabletPoll.json().session.messages[0].id, message.json().id);
  const event = await current.app.inject({ method: "POST", url: `/v1/device/pure-one/canvas/sessions/${sessionId}/events`, headers: deviceHeaders, payload: { message_id: message.json().id, action_id: "pizza123", value: "pizza" } });
  assert.equal(event.statusCode, 201);
  const events = await current.app.inject({ method: "GET", url: `/v1/devices/pure-one/canvas/sessions/${sessionId}/events`, headers: clientHeaders });
  assert.equal(events.json().events[0].value, "pizza");
  const ack = await current.app.inject({ method: "POST", url: `/v1/devices/pure-one/canvas/sessions/${sessionId}/events/${event.json().id}/ack`, headers: clientHeaders });
  assert.equal(ack.statusCode, 204);
});
