import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { operationRegistry } from "@paperboard/core";
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
    deviceStatus: async () => ({ foreground: "paperboard" }),
    deviceApps: async () => ({ apps: ["paperboard"] }),
    deviceLaunch: async () => ({ launched: "paperboard" }),
    deviceExit: async () => ({ returned: true }),
    deviceScreenshot: async () => Buffer.from("89504e470d0a1a0a", "hex"),
    createScreenSession: async () => ({ id: "session-12345678" }),
    listScreenSessions: async () => ({ sessions: [] }),
    getScreenSession: async () => ({ id: "session-12345678", messages: [] }),
    presentScreen: async () => ({ id: "message-12345678" }),
    screenEvents: async () => ({ events: [] }),
    acknowledgeScreenEvent: async () => undefined,
    closeScreenSession: async () => ({ status: "closed" }),
  };
  const server = createPaperboardMcpServer(relay);
  const client = new Client({ name: "paperboard-test", version: "1.0.0" });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  context.after(async () => { await client.close(); await server.close(); });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);

  const listed = await client.listTools();
  assert.deepEqual(
    listed.tools.map((tool) => tool.name).sort(),
    [...operationRegistry.map((item) => item.mcp), "dashboard_show_image", "dashboard_wait"].sort(),
    "MCP must expose every public v2 operation plus its two safe convenience tools",
  );
  const response = await client.callTool({ name: "dashboard_show", arguments: {
    device: "paper-pure", title: "Building", body: "Almost there", progress: 42,
    replace_key: "build-status",
  } });
  assert.equal(response.isError, undefined);
  assert.equal((calls[0]?.[1] as { kind: string }).kind, "progress");
  assert.equal((calls[0]?.[1] as { progress: number }).progress, 42);
  assert.match(String(calls[0]?.[2]), /^[0-9a-f-]{36}$/);
});

test("uses the configured default device when a tool call omits it", async (context) => {
  let selectedDevice = "";
  const relay = {
    uploadAsset: async () => ({}), show: async () => ({}), update: async () => ({}),
    list: async (device: string) => { selectedDevice = device; return { cards: [] }; },
    get: async () => ({}), delete: async () => undefined, clear: async () => ({}), status: async () => ({}),
    command: async () => ({}), commandStatus: async () => ({}), deviceStatus: async () => ({}), deviceApps: async () => ({}),
    deviceLaunch: async () => ({}), deviceExit: async () => ({}), deviceScreenshot: async () => Buffer.alloc(0),
    createScreenSession: async () => ({}), listScreenSessions: async () => ({}), getScreenSession: async () => ({}),
    presentScreen: async () => ({}), screenEvents: async () => ({}), acknowledgeScreenEvent: async () => undefined,
    closeScreenSession: async () => ({}),
  } as PaperboardToolClient;
  const server = createPaperboardMcpServer(relay, { defaultDevice: "paper-pure" });
  const client = new Client({ name: "paperboard-default-device-test", version: "1.0.0" });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  context.after(async () => { await client.close(); await server.close(); });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);

  const response = await client.callTool({ name: "dashboard_list", arguments: {} });
  assert.equal(response.isError, undefined);
  assert.equal(selectedDevice, "paper-pure");
});
