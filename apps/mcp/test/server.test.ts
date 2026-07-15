import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import assert from "node:assert/strict";
import test from "node:test";
import { createPaperboardMcpServer, type PaperboardToolClient } from "../src/server.js";

test("lists the agent tools and maps progress input to a replaceable card", async (context) => {
  const calls: unknown[][] = [];
  const relay: PaperboardToolClient = {
    uploadAsset: async () => ({ id: "asset-12345678", sha256: "a".repeat(64) }),
    show: async (...args) => { calls.push(args); return { id: "card-12345678", cursor: 7 }; },
    update: async () => ({ id: "card-12345678", cursor: 8 }),
    list: async () => ({ cards: [] }),
    get: async () => ({ id: "card-12345678", cursor: 7 }),
    delete: async () => undefined,
    clear: async () => ({ removed: 1 }),
    status: async () => ({ queued: 1 }),
    command: async () => ({ id: "command-12345678", status: "queued" }),
    commandStatus: async () => ({ id: "command-12345678", status: "completed" }),
    createCanvasSession: async () => ({ id: "session-12345678" }),
    listCanvasSessions: async () => ({ sessions: [] }),
    getCanvasSession: async () => ({ id: "session-12345678", messages: [] }),
    sendCanvasMessage: async () => ({ id: "message-12345678" }),
    canvasEvents: async () => ({ events: [] }),
    acknowledgeCanvasEvent: async () => undefined,
    closeCanvasSession: async () => ({ status: "closed" }),
  };
  const server = createPaperboardMcpServer(relay);
  const client = new Client({ name: "paperboard-test", version: "1.0.0" });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  context.after(async () => { await client.close(); await server.close(); });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);

  const listed = await client.listTools();
  assert.deepEqual(listed.tools.map((tool) => tool.name).sort(), [
    "canvas_ack", "canvas_close", "canvas_events", "canvas_list", "canvas_send", "canvas_start", "canvas_status",
    "paperboard_clear", "paperboard_control", "paperboard_delete", "paperboard_get", "paperboard_list",
    "paperboard_show", "paperboard_show_image", "paperboard_status", "paperboard_update", "paperboard_wait",
  ]);
  const response = await client.callTool({ name: "paperboard_show", arguments: {
    device: "paper-pure", title: "Building", body: "Almost there", progress: 42,
    replace_key: "build-status",
  } });
  assert.equal(response.isError, undefined);
  assert.equal((calls[0]?.[1] as { kind: string }).kind, "progress");
  assert.equal((calls[0]?.[1] as { progress: number }).progress, 42);
  assert.match(String(calls[0]?.[2]), /^[0-9a-f-]{36}$/);
});
