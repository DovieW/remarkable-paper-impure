import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import sharp from "sharp";
import { hashToken } from "@paperboard/core";
import { ProviderManager } from "../src/providers.js";
import { Store } from "../src/store.js";

test("Terminus adapter uses the TRMNL display contract and creates one ambient frame", async (context) => {
  const root = mkdtempSync(join(tmpdir(), "paperboard-provider-"));
  const store = new Store(join(root, "provider.sqlite"), join(root, "assets"));
  store.createDevice("paper-pure", hashToken("test-device-token"));
  const image = await sharp({ create: { width: 80, height: 40, channels: 3, background: "white" } }).png().toBuffer();
  let displayRequests = 0;
  const upstream = createServer((request, response) => {
    if (request.url === "/api/display") {
      displayRequests += 1;
      assert.equal(request.headers.id, "paper-pure-upstream");
      assert.equal(request.headers["access-token"], "terminus-test-token");
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify({ status: 0, image_url: "http://browser-facing.example/screen.png?frame=1", refresh_rate: "60" }));
      return;
    }
    if (request.url === "/screen.png?frame=1") {
      response.setHeader("content-type", "image/png");
      response.end(image);
      return;
    }
    response.statusCode = 404;
    response.end();
  });
  await new Promise<void>((resolve) => upstream.listen(0, "127.0.0.1", resolve));
  const address = upstream.address();
  assert.ok(address && typeof address !== "string");
  const baseUrl = `http://127.0.0.1:${address.port}`;
  const manager = new ProviderManager(store, Buffer.alloc(32, 5), "https://paperboard.example");
  manager.set("paper-pure", {
    kind: "terminus", base_url: baseUrl, device_id: "paper-pure-upstream",
    access_token: "terminus-test-token", allow_private_http: true,
  });
  context.after(() => { manager.stop(); upstream.close(); store.close(); rmSync(root, { recursive: true, force: true }); });

  await manager.pollDevice("paper-pure");
  await manager.pollDevice("paper-pure");
  assert.equal(displayRequests, 2);
  const cards = store.activeCards("paper-pure", "https://paperboard.example");
  assert.equal(cards.length, 1);
  assert.equal(cards[0]?.kind, "image");
  assert.equal(cards[0]?.priority, "ambient");
});
