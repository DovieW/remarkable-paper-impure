import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { PaperboardClient } from "@paperboard/client";
import { canvasMessageInputSchema, cardInputSchema, cardPatchSchema, paperboardCommandActionSchema } from "@paperboard/core";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { extname } from "node:path";
import { z } from "zod";

export type PaperboardToolClient = Pick<PaperboardClient, "uploadAsset" | "show" | "update" | "list" | "get" | "delete" | "clear" | "status" | "command" | "commandStatus" | "tabletStatus" | "tabletApps" | "tabletLaunch" | "tabletReturn" | "tabletScreenshot" | "createCanvasSession" | "listCanvasSessions" | "getCanvasSession" | "sendCanvasMessage" | "canvasEvents" | "acknowledgeCanvasEvent" | "closeCanvasSession">;

export interface PaperboardMcpServerOptions {
  defaultDevice?: string;
}

const result = (value: unknown) => ({
  content: [{ type: "text" as const, text: JSON.stringify(value) }],
  structuredContent: value as Record<string, unknown>,
});

export function createPaperboardMcpServer(client: PaperboardToolClient, options: PaperboardMcpServerOptions = {}): McpServer {
  const server = new McpServer({ name: "paperboard", version: "1.0.0" });
  const device = options.defaultDevice
    ? z.string().default(options.defaultDevice)
    : z.string();

  server.registerTool("paperboard_show", {
    title: "Show on Paperboard dashboard",
    description: "Use for dashboard requests. Queue an ambient Paperboard card without launching an app or interrupting the current foreground app. Do not use this for a screen request; screens belong in Paperboard Canvas.",
    inputSchema: {
      device, title: z.string(), body: z.string().default(""),
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
      device, card: z.string(), title: z.string().optional(), body: z.string().optional(),
      progress: z.number().min(0).max(100).optional(), priority: z.enum(["normal", "urgent", "ambient"]).optional(),
      ttl_seconds: z.number().int().min(1).max(86400).optional(), pinned: z.boolean().optional(),
    },
  }, async ({ device, card, ...patch }) => result(await client.update(device, card, cardPatchSchema.parse(patch))));

  server.registerTool("paperboard_show_image", {
    title: "Show image on Paperboard", description: "Upload a local PNG, JPEG, or BMP and queue it as a normalized Paperboard image card.",
    inputSchema: { device, path: z.string(), title: z.string(), body: z.string().default(""), priority: z.enum(["normal", "urgent", "ambient"]).default("normal"), ttl_seconds: z.number().int().min(1).max(86400).default(300), pinned: z.boolean().default(false), replace_key: z.string().optional() },
  }, async (input) => {
    const extension = extname(input.path).toLowerCase(); const contentType = extension === ".jpg" || extension === ".jpeg" ? "image/jpeg" : extension === ".bmp" ? "image/bmp" : "image/png";
    const asset = await client.uploadAsset(input.device, await readFile(input.path), contentType);
    return result(await client.show(input.device, cardInputSchema.parse({ kind: "image", title: input.title, body: input.body, asset_id: asset.id, priority: input.priority, ttl_seconds: input.ttl_seconds, pinned: input.pinned, replace_key: input.replace_key }), randomUUID()));
  });

  server.registerTool("paperboard_list", { title: "List Paperboard dashboard cards", description: "List active dashboard cards in display order.", inputSchema: { device } }, async ({ device }) => result(await client.list(device)));
  server.registerTool("paperboard_get", { title: "Get Paperboard dashboard card", description: "Read one active dashboard card.", inputSchema: { device, card: z.string() } }, async ({ device, card }) => result(await client.get(device, card)));
  server.registerTool("paperboard_delete", { title: "Delete Paperboard dashboard card", description: "Delete one dashboard card without clearing the queue.", inputSchema: { device, card: z.string() } }, async ({ device, card }) => { await client.delete(device, card); return result({ deleted: card }); });

  server.registerTool("paperboard_clear", {
    title: "Clear Paperboard", description: "Dismiss every queued card for a device.",
    inputSchema: { device },
  }, async ({ device }) => result(await client.clear(device)));

  server.registerTool("paperboard_status", {
    title: "Paperboard dashboard status", description: "Read dashboard queue, delivery, foreground, visible card, mode, and tablet heartbeat state.",
    inputSchema: { device },
  }, async ({ device }) => result(await client.status(device)));

  server.registerTool("paperboard_control", {
    title: "Navigate foreground Paperboard", description: "Run a short-lived semantic action only while Paperboard is foregrounded.",
    inputSchema: { device, action: paperboardCommandActionSchema, wait: z.boolean().default(true) },
  }, async ({ device, action, wait }) => {
    const created = await client.command(device, action); if (!wait) return result(created); const id = String(created.id);
    for (let attempt = 0; attempt < 20; attempt++) { const state = await client.commandStatus(device, id); if (["completed", "failed", "expired"].includes(String(state.status))) return result(state); await new Promise((resolve) => setTimeout(resolve, 250)); }
    throw new Error("Paperboard command did not complete");
  });

  server.registerTool("paperboard_wait", {
    title: "Wait for Paperboard delivery", description: "Wait until a card is acknowledged by the tablet or currently visible.",
    inputSchema: { device, card: z.string(), until: z.enum(["acknowledged", "visible"]).default("acknowledged"), timeout_seconds: z.number().int().min(1).max(120).default(30) },
  }, async ({ device, card, until, timeout_seconds }) => {
    const deadline = Date.now() + timeout_seconds * 1000;
    while (Date.now() < deadline) { const state = await client.status(device); const visible = state.visible_card as { id?: string } | null | undefined; if (until === "visible" && visible?.id === card) return result(state); const item = await client.get(device, card) as { cursor?: number }; if (until === "acknowledged" && item.cursor !== undefined && Number(state.last_ack_cursor ?? 0) >= item.cursor) return result(state); await new Promise((resolve) => setTimeout(resolve, 1000)); }
    throw new Error(`Timed out waiting for ${until}`);
  });

  server.registerTool("tablet_status", { title: "Tablet status", description: "Read the foreground application and safe tablet-control capability state.", inputSchema: { device } }, async ({ device }) => result(await client.tabletStatus(device)));
  server.registerTool("tablet_apps", { title: "List tablet applications", description: "List installed AppLoad package identifiers that are eligible for explicit launch.", inputSchema: { device } }, async ({ device }) => result(await client.tabletApps(device)));
  server.registerTool("tablet_launch", { title: "Launch tablet application", description: "Explicitly foreground one installed AppLoad package. This cannot unlock the tablet.", inputSchema: { device, app_id: z.string() } }, async ({ device, app_id }) => result(await client.tabletLaunch(device, app_id)));
  server.registerTool("tablet_return", { title: "Return tablet", description: "Return from a custom application to AppLoad or the stock interface.", inputSchema: { device } }, async ({ device }) => result(await client.tabletReturn(device)));
  server.registerTool("tablet_screenshot", { title: "Capture tablet display", description: "Return one ephemeral PNG of the current unlocked tablet display; the relay does not retain it. This observes the physical display and is distinct from creating a Paperboard Canvas screen.", inputSchema: { device } }, async ({ device }) => {
    const png = await client.tabletScreenshot(device);
    return { content: [{ type: "image" as const, data: png.toString("base64"), mimeType: "image/png" }], structuredContent: { mime_type: "image/png", bytes: png.length } };
  });

  server.registerTool("canvas_start", { title: "Start Paperboard Canvas screen", description: "Use for screen requests. Create an interactive Paperboard Canvas session; this does not launch the tablet app by itself.", inputSchema: { device, title: z.string() } }, async ({ device, title }) => result(await client.createCanvasSession(device, title)));
  server.registerTool("canvas_list", { title: "List Paperboard Canvas screens", description: "List interactive Paperboard Canvas sessions/screens.", inputSchema: { device } }, async ({ device }) => result(await client.listCanvasSessions(device)));
  server.registerTool("canvas_status", { title: "Get Paperboard Canvas screen", description: "Read an interactive Paperboard Canvas session and its messages.", inputSchema: { device, session: z.string() } }, async ({ device, session }) => result(await client.getCanvasSession(device, session)));
  server.registerTool("canvas_send", {
    title: "Update Paperboard Canvas screen", description: "Send content and structured touch actions to an interactive Paperboard Canvas screen. The title is already rendered as the screen heading; do not repeat the same text as the first Markdown heading in body.",
    inputSchema: { device, session: z.string(), title: z.string(), body: z.string().default(""), actions: z.array(z.unknown()).default([]), replace_key: z.string().optional() },
  }, async ({ device, session, ...message }) => result(await client.sendCanvasMessage(device, session, canvasMessageInputSchema.parse(message))));
  server.registerTool("canvas_events", { title: "Read Paperboard Canvas interactions", description: "Read user touch-response events from an interactive screen after a cursor.", inputSchema: { device, session: z.string(), after: z.number().int().min(0).default(0) } }, async ({ device, session, after }) => result(await client.canvasEvents(device, session, after)));
  server.registerTool("canvas_ack", { title: "Acknowledge Paperboard Canvas interaction", description: "Acknowledge one processed Canvas screen event.", inputSchema: { device, session: z.string(), event: z.string() } }, async ({ device, session, event }) => { await client.acknowledgeCanvasEvent(device, session, event); return result({ acknowledged: event }); });
  server.registerTool("canvas_close", { title: "Close Paperboard Canvas screen", description: "Close a Canvas screen without launching or returning the tablet app.", inputSchema: { device, session: z.string() } }, async ({ device, session }) => result(await client.closeCanvasSession(device, session)));

  return server;
}
