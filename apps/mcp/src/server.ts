import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { PaperboardClient } from "@paperboard/client";
import { canvasMessageInputSchema, cardInputSchema, cardPatchSchema, paperboardCommandActionSchema } from "@paperboard/core";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { extname } from "node:path";
import { z } from "zod";

export type PaperboardToolClient = Pick<PaperboardClient, "uploadAsset" | "show" | "update" | "list" | "get" | "delete" | "clear" | "status" | "command" | "commandStatus" | "createCanvasSession" | "listCanvasSessions" | "getCanvasSession" | "sendCanvasMessage" | "canvasEvents" | "acknowledgeCanvasEvent" | "closeCanvasSession">;

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

  server.registerTool("paperboard_show_image", {
    title: "Show image on Paperboard", description: "Upload a local PNG, JPEG, or BMP and queue it as a normalized Paperboard image card.",
    inputSchema: { device: z.string(), path: z.string(), title: z.string(), body: z.string().default(""), priority: z.enum(["normal", "urgent", "ambient"]).default("normal"), ttl_seconds: z.number().int().min(1).max(86400).default(300), pinned: z.boolean().default(false), replace_key: z.string().optional() },
  }, async (input) => {
    const extension = extname(input.path).toLowerCase(); const contentType = extension === ".jpg" || extension === ".jpeg" ? "image/jpeg" : extension === ".bmp" ? "image/bmp" : "image/png";
    const asset = await client.uploadAsset(input.device, await readFile(input.path), contentType);
    return result(await client.show(input.device, cardInputSchema.parse({ kind: "image", title: input.title, body: input.body, asset_id: asset.id, priority: input.priority, ttl_seconds: input.ttl_seconds, pinned: input.pinned, replace_key: input.replace_key }), randomUUID()));
  });

  server.registerTool("paperboard_list", { title: "List Paperboard cards", description: "List active cards in display order.", inputSchema: { device: z.string() } }, async ({ device }) => result(await client.list(device)));
  server.registerTool("paperboard_get", { title: "Get Paperboard card", description: "Read one active card.", inputSchema: { device: z.string(), card: z.string() } }, async ({ device, card }) => result(await client.get(device, card)));
  server.registerTool("paperboard_delete", { title: "Delete Paperboard card", description: "Delete one card without clearing the queue.", inputSchema: { device: z.string(), card: z.string() } }, async ({ device, card }) => { await client.delete(device, card); return result({ deleted: card }); });

  server.registerTool("paperboard_clear", {
    title: "Clear Paperboard", description: "Dismiss every queued card for a device.",
    inputSchema: { device: z.string() },
  }, async ({ device }) => result(await client.clear(device)));

  server.registerTool("paperboard_status", {
    title: "Paperboard status", description: "Read queue, delivery, foreground, visible card, mode, and tablet heartbeat state.",
    inputSchema: { device: z.string() },
  }, async ({ device }) => result(await client.status(device)));

  server.registerTool("paperboard_control", {
    title: "Navigate foreground Paperboard", description: "Run a short-lived semantic action only while Paperboard is foregrounded.",
    inputSchema: { device: z.string(), action: paperboardCommandActionSchema, wait: z.boolean().default(true) },
  }, async ({ device, action, wait }) => {
    const created = await client.command(device, action); if (!wait) return result(created); const id = String(created.id);
    for (let attempt = 0; attempt < 20; attempt++) { const state = await client.commandStatus(device, id); if (["completed", "failed", "expired"].includes(String(state.status))) return result(state); await new Promise((resolve) => setTimeout(resolve, 250)); }
    throw new Error("Paperboard command did not complete");
  });

  server.registerTool("paperboard_wait", {
    title: "Wait for Paperboard delivery", description: "Wait until a card is acknowledged by the tablet or currently visible.",
    inputSchema: { device: z.string(), card: z.string(), until: z.enum(["acknowledged", "visible"]).default("acknowledged"), timeout_seconds: z.number().int().min(1).max(120).default(30) },
  }, async ({ device, card, until, timeout_seconds }) => {
    const deadline = Date.now() + timeout_seconds * 1000;
    while (Date.now() < deadline) { const state = await client.status(device); const visible = state.visible_card as { id?: string } | null | undefined; if (until === "visible" && visible?.id === card) return result(state); const item = await client.get(device, card) as { cursor?: number }; if (until === "acknowledged" && item.cursor !== undefined && Number(state.last_ack_cursor ?? 0) >= item.cursor) return result(state); await new Promise((resolve) => setTimeout(resolve, 1000)); }
    throw new Error(`Timed out waiting for ${until}`);
  });

  server.registerTool("canvas_start", { title: "Start Canvas session", description: "Create a manually opened interactive Canvas conversation.", inputSchema: { device: z.string(), title: z.string() } }, async ({ device, title }) => result(await client.createCanvasSession(device, title)));
  server.registerTool("canvas_list", { title: "List Canvas sessions", description: "List Canvas conversations.", inputSchema: { device: z.string() } }, async ({ device }) => result(await client.listCanvasSessions(device)));
  server.registerTool("canvas_status", { title: "Get Canvas session", description: "Read a Canvas session and its messages.", inputSchema: { device: z.string(), session: z.string() } }, async ({ device, session }) => result(await client.getCanvasSession(device, session)));
  server.registerTool("canvas_send", {
    title: "Send to Canvas", description: "Send a message with structured touch actions to Canvas.",
    inputSchema: { device: z.string(), session: z.string(), title: z.string(), body: z.string().default(""), actions: z.array(z.unknown()).default([]), replace_key: z.string().optional() },
  }, async ({ device, session, ...message }) => result(await client.sendCanvasMessage(device, session, canvasMessageInputSchema.parse(message))));
  server.registerTool("canvas_events", { title: "Read Canvas interactions", description: "Read user touch-response events after a cursor.", inputSchema: { device: z.string(), session: z.string(), after: z.number().int().min(0).default(0) } }, async ({ device, session, after }) => result(await client.canvasEvents(device, session, after)));
  server.registerTool("canvas_ack", { title: "Acknowledge Canvas interaction", description: "Acknowledge one processed Canvas event.", inputSchema: { device: z.string(), session: z.string(), event: z.string() } }, async ({ device, session, event }) => { await client.acknowledgeCanvasEvent(device, session, event); return result({ acknowledged: event }); });
  server.registerTool("canvas_close", { title: "Close Canvas session", description: "Close a Canvas conversation without launching the tablet app.", inputSchema: { device: z.string(), session: z.string() } }, async ({ device, session }) => result(await client.closeCanvasSession(device, session)));

  return server;
}
