import assert from "node:assert/strict";
import { once } from "node:events";
import test from "node:test";
import type { AddressInfo } from "node:net";
import type { TabletController, TabletStatus } from "../src/controller.js";
import { buildRemoteServer } from "../src/server.js";

class FakeController implements TabletController {
  inputs: unknown[] = [];
  controls: string[] = [];
  async capture() { return Buffer.from("\x89PNG\r\n\x1a\nframe", "binary"); }
  async status(): Promise<TabletStatus> { return { platform: "imx93-tatsu", architecture: "aarch64", foreground: "stock", lock_state: "unknown", screenshot: true, input_helper: true }; }
  async tap(x: number, y: number) { this.inputs.push({ action: "tap", x, y }); }
  async swipe(x1: number, y1: number, x2: number, y2: number, durationMs: number) { this.inputs.push({ action: "swipe", x1, y1, x2, y2, durationMs }); }
  async control(action: "paperboard" | "screen" | "exit") { this.controls.push(action); return { accepted: action }; }
  async close() {}
}

async function fixture(context: test.TestContext) {
  const controller = new FakeController();
  const current = buildRemoteServer(controller, { inputEnabled: true, killSwitchPath: "/path/that/does/not/exist" });
  current.server.listen(0, "127.0.0.1");
  await once(current.server, "listening");
  context.after(() => current.server.close());
  const address = current.server.address() as AddressInfo;
  const base = `http://127.0.0.1:${address.port}`;
  const session = await (await fetch(`${base}/api/session`)).json() as { token: string };
  const headers = { "x-paper-remote-token": session.token, "content-type": "application/json" };
  return { controller, base, headers };
}

test("serves an ephemeral authenticated frame", async context => {
  const { base, headers } = await fixture(context);
  assert.equal((await fetch(`${base}/api/frame`)).status, 403);
  const response = await fetch(`${base}/api/frame`, { headers });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store, max-age=0");
  assert.equal(Buffer.from(await response.arrayBuffer()).subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
});

test("allows bounded input only when the private endpoint policy enables it", async context => {
  const { controller, base, headers } = await fixture(context);
  const started = performance.now();
  assert.equal((await fetch(`${base}/api/input`, { method: "POST", headers, body: JSON.stringify({ action: "tap", x: 1403, y: 1871 }) })).status, 200);
  assert.ok(performance.now() - started < 250, "warm local input acknowledgement exceeded 250 ms");
  assert.deepEqual(controller.inputs, [{ action: "tap", x: 1403, y: 1871 }]);
  assert.equal((await fetch(`${base}/api/input`, { method: "POST", headers, body: JSON.stringify({ action: "tap", x: 1404, y: 0 }) })).status, 400);
});

test("works behind the configured Tailscale Serve subpath", async context => {
  const controller = new FakeController();
  const current = buildRemoteServer(controller, { basePath: "/remote" });
  current.server.listen(0, "127.0.0.1");
  await once(current.server, "listening");
  context.after(() => current.server.close());
  const address = current.server.address() as AddressInfo;
  const response = await fetch(`http://127.0.0.1:${address.port}/remote/`);
  assert.equal(response.status, 200);
  assert.match(await response.text(), /Paper Pure Remote/);
  assert.equal((await fetch(`http://127.0.0.1:${address.port}/remote/app.js`)).status, 200);
  assert.equal((await fetch(`http://127.0.0.1:${address.port}/remote/api/session`)).status, 200);
});

test("exposes only fixed semantic app controls", async context => {
  const { controller, base, headers } = await fixture(context);
  assert.equal((await fetch(`${base}/api/control`, { method: "POST", headers, body: JSON.stringify({ action: "screen" }) })).status, 200);
  const exited = await fetch(`${base}/api/control`, { method: "POST", headers, body: JSON.stringify({ action: "exit" }) });
  assert.equal(exited.status, 200);
  assert.deepEqual(controller.controls, ["screen", "exit"]);
  assert.equal((await fetch(`${base}/api/control`, { method: "POST", headers, body: JSON.stringify({ action: "shell" }) })).status, 400);
});
