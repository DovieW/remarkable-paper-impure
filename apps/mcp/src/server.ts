import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { PaperboardClient } from "@paperboard/client";
import { cardInputSchema, cardPatchSchema } from "@paperboard/core";
import { randomUUID } from "node:crypto";
import { z } from "zod";

export type PaperboardToolClient = Pick<PaperboardClient, "show" | "update" | "clear" | "status">;

const result = (value: unknown) => ({
  content: [{ type: "text" as const, text: JSON.stringify(value) }],
  structuredContent: value as Record<string, unknown>,
});

export function createPaperboardMcpServer(client: PaperboardToolClient): McpServer {
  const server = new McpServer({ name: "paperboard", version: "1.0.0" });

  server.registerTool("paperboard_show", {
    title: "Show on Paperboard",
    description: "Queue a final message or progress card on a Paperboard device without interrupting its current app.",
    inputSchema: {
      device: z.string(), title: z.string(), body: z.string().default(""),
      progress: z.number().min(0).max(100).optional(),
      priority: z.enum(["normal", "urgent", "ambient"]).default("normal"),
      ttl_seconds: z.number().int().min(1).max(86400).default(300),
      pinned: z.boolean().default(false), replace_key: z.string().optional(),
    },
  }, async (input) => result(await client.show(input.device, cardInputSchema.parse({
    kind: input.progress === undefined ? "message" : "progress", ...input,
  }), randomUUID())));

  server.registerTool("paperboard_update", {
    title: "Update Paperboard card",
    description: "Replace fields on an existing queued card, commonly for progress updates.",
    inputSchema: {
      device: z.string(), card: z.string(), title: z.string().optional(), body: z.string().optional(),
      progress: z.number().min(0).max(100).optional(), priority: z.enum(["normal", "urgent", "ambient"]).optional(),
      ttl_seconds: z.number().int().min(1).max(86400).optional(), pinned: z.boolean().optional(),
    },
  }, async ({ device, card, ...patch }) => result(await client.update(device, card, cardPatchSchema.parse(patch))));

  server.registerTool("paperboard_clear", {
    title: "Clear Paperboard", description: "Dismiss every queued card for a device.",
    inputSchema: { device: z.string() },
  }, async ({ device }) => result(await client.clear(device)));

  server.registerTool("paperboard_status", {
    title: "Paperboard status", description: "Read queue, cursor, provider, and last tablet heartbeat status.",
    inputSchema: { device: z.string() },
  }, async ({ device }) => result(await client.status(device)));

  return server;
}
