import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import assert from "node:assert/strict";
import test from "node:test";
import { createPaperboardMcpServer, type PaperboardToolClient } from "../src/server.js";

test("lists the agent tools and maps progress input to a replaceable card", async (context) => {
  const calls: unknown[][] = [];
  const relay: PaperboardToolClient = {
    show: async (...args) => { calls.push(args); return { id: "card-12345678", cursor: 7 }; },
    update: async () => ({ id: "card-12345678", cursor: 8 }),
    clear: async () => ({ removed: 1 }),
    status: async () => ({ queued: 1 }),
  };
  const server = createPaperboardMcpServer(relay);
  const client = new Client({ name: "paperboard-test", version: "1.0.0" });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  context.after(async () => { await client.close(); await server.close(); });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);

  const listed = await client.listTools();
  assert.deepEqual(listed.tools.map((tool) => tool.name).sort(), [
    "paperboard_clear", "paperboard_show", "paperboard_status", "paperboard_update",
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
