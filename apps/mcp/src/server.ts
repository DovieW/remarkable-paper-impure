import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { PaperboardClient } from "@paperboard/client";
import { operation, screenMessageInputSchema, cardInputSchema, cardPatchSchema, paperboardCommandActionSchema } from "@paperboard/core";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { extname } from "node:path";
import { z } from "zod";

export type PaperboardToolClient = Pick<PaperboardClient, "uploadAsset" | "show" | "update" | "list" | "get" | "delete" | "clear" | "status" | "command" | "commandStatus" | "deviceStatus" | "deviceApps" | "deviceLaunch" | "deviceExit" | "deviceScreenshot" | "createScreenSession" | "listScreenSessions" | "getScreenSession" | "presentScreen" | "screenEvents" | "acknowledgeScreenEvent" | "closeScreenSession">;

export interface PaperboardMcpServerOptions {
  defaultDevice?: string;
}

const result = (value: unknown) => ({
  content: [{ type: "text" as const, text: JSON.stringify(value) }],
  structuredContent: value as Record<string, unknown>,
});

export function createPaperboardMcpServer(client: PaperboardToolClient, options: PaperboardMcpServerOptions = {}): McpServer {
  const server = new McpServer({ name: "paperboard", version: "2.0.0" });
  const device = options.defaultDevice
    ? z.string().default(options.defaultDevice)
    : z.string();

  server.registerTool(operation("dashboard.asset.upload").mcp, {
    title: "Upload Paperboard asset",
    description: "Normalize and upload a local PNG, JPEG, or BMP without creating a dashboard card.",
    inputSchema: { device, path: z.string() },
  }, async ({ device, path }) => {
    const extension = extname(path).toLowerCase();
    const contentType = extension === ".jpg" || extension === ".jpeg" ? "image/jpeg" : extension === ".bmp" ? "image/bmp" : "image/png";
    return result(await client.uploadAsset(device, await readFile(path), contentType));
  });

  server.registerTool(operation("dashboard.card.create").mcp, {
    title: "Show on Paperboard dashboard",
    description: "Use for dashboard requests. Queue an ambient Paperboard card without launching an app or interrupting the current foreground app. Do not use this for a screen request; interactive content belongs in Paperboard Screen.",
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

  server.registerTool(operation("dashboard.card.update").mcp, {
    title: "Update Paperboard card",
    description: "Replace fields on an existing queued card, commonly for progress updates.",
    inputSchema: {
      device, card: z.string(), title: z.string().optional(), body: z.string().optional(),
      progress: z.number().min(0).max(100).optional(), priority: z.enum(["normal", "urgent", "ambient"]).optional(),
      ttl_seconds: z.number().int().min(1).max(86400).optional(), pinned: z.boolean().optional(),
    },
  }, async ({ device, card, ...patch }) => result(await client.update(device, card, cardPatchSchema.parse(patch))));

  server.registerTool("dashboard_show_image", {
    title: "Show image on Paperboard", description: "Upload a local PNG, JPEG, or BMP and queue it as a normalized Paperboard image card.",
    inputSchema: { device, path: z.string(), title: z.string(), body: z.string().default(""), priority: z.enum(["normal", "urgent", "ambient"]).default("normal"), ttl_seconds: z.number().int().min(1).max(86400).default(300), pinned: z.boolean().default(false), replace_key: z.string().optional() },
  }, async (input) => {
    const extension = extname(input.path).toLowerCase(); const contentType = extension === ".jpg" || extension === ".jpeg" ? "image/jpeg" : extension === ".bmp" ? "image/bmp" : "image/png";
    const asset = await client.uploadAsset(input.device, await readFile(input.path), contentType);
    return result(await client.show(input.device, cardInputSchema.parse({ kind: "image", title: input.title, body: input.body, asset_id: asset.id, priority: input.priority, ttl_seconds: input.ttl_seconds, pinned: input.pinned, replace_key: input.replace_key }), randomUUID()));
  });

  server.registerTool(operation("dashboard.card.list").mcp, { title: "List Paperboard dashboard cards", description: "List active dashboard cards in display order.", inputSchema: { device } }, async ({ device }) => result(await client.list(device)));
  server.registerTool(operation("dashboard.card.get").mcp, { title: "Get Paperboard dashboard card", description: "Read one active dashboard card.", inputSchema: { device, card: z.string() } }, async ({ device, card }) => result(await client.get(device, card)));
  server.registerTool(operation("dashboard.card.delete").mcp, { title: "Delete Paperboard dashboard card", description: "Delete one dashboard card without clearing the queue.", inputSchema: { device, card: z.string() } }, async ({ device, card }) => { await client.delete(device, card); return result({ deleted: card }); });

  server.registerTool(operation("dashboard.clear").mcp, {
    title: "Clear Paperboard", description: "Dismiss every queued card for a device.",
    inputSchema: { device },
  }, async ({ device }) => result(await client.clear(device)));

  server.registerTool(operation("device.status").mcp, {
    title: "Paperboard dashboard status", description: "Read dashboard queue, delivery, foreground, visible card, mode, and tablet heartbeat state.",
    inputSchema: { device },
  }, async ({ device }) => result(await client.status(device)));

  server.registerTool(operation("device.command").mcp, {
    title: "Navigate foreground Paperboard", description: "Run a short-lived semantic action only while Paperboard is foregrounded.",
    inputSchema: { device, action: paperboardCommandActionSchema, wait: z.boolean().default(true) },
  }, async ({ device, action, wait }) => {
    const created = await client.command(device, action); if (!wait) return result(created); const id = String(created.id);
    for (let attempt = 0; attempt < 20; attempt++) { const state = await client.commandStatus(device, id); if (["completed", "failed", "expired"].includes(String(state.status))) return result(state); await new Promise((resolve) => setTimeout(resolve, 250)); }
    throw new Error("Paperboard command did not complete");
  });

  server.registerTool(operation("device.command.status").mcp, {
    title: "Read tablet command status", description: "Read the final or pending state of one bounded semantic command.",
    inputSchema: { device, command: z.string() },
  }, async ({ device, command }) => result(await client.commandStatus(device, command)));

  server.registerTool("dashboard_wait", {
    title: "Wait for Paperboard delivery", description: "Wait until a card is acknowledged by the tablet or currently visible.",
    inputSchema: { device, card: z.string(), until: z.enum(["acknowledged", "visible"]).default("acknowledged"), timeout_seconds: z.number().int().min(1).max(120).default(30) },
  }, async ({ device, card, until, timeout_seconds }) => {
    const deadline = Date.now() + timeout_seconds * 1000;
    while (Date.now() < deadline) { const state = await client.status(device); const visible = state.visible_card as { id?: string } | null | undefined; if (until === "visible" && visible?.id === card) return result(state); const item = await client.get(device, card) as { cursor?: number }; if (until === "acknowledged" && item.cursor !== undefined && Number(state.last_ack_cursor ?? 0) >= item.cursor) return result(state); await new Promise((resolve) => setTimeout(resolve, 1000)); }
    throw new Error(`Timed out waiting for ${until}`);
  });

  server.registerTool(operation("device.apps").mcp, { title: "List tablet applications", description: "List installed AppLoad package identifiers that are eligible for explicit launch.", inputSchema: { device } }, async ({ device }) => result(await client.deviceApps(device)));
  server.registerTool(operation("device.launch").mcp, { title: "Launch tablet application", description: "Explicitly foreground one installed AppLoad package. This cannot unlock the tablet.", inputSchema: { device, app_id: z.string() } }, async ({ device, app_id }) => result(await client.deviceLaunch(device, app_id)));
  server.registerTool(operation("device.exit").mcp, { title: "Exit tablet application", description: "Exit the current custom application to AppLoad or the stock interface.", inputSchema: { device } }, async ({ device }) => result(await client.deviceExit(device)));
  server.registerTool(operation("device.screenshot").mcp, { title: "Capture tablet display", description: "Return one ephemeral PNG of the current unlocked tablet display; the relay does not retain it.", inputSchema: { device } }, async ({ device }) => {
    const png = await client.deviceScreenshot(device);
    return { content: [{ type: "image" as const, data: png.toString("base64"), mimeType: "image/png" }], structuredContent: { mime_type: "image/png", bytes: png.length } };
  });

  server.registerTool(operation("screen.session.create").mcp, { title: "Start Paperboard Screen", description: "Create an interactive Paperboard Screen session.", inputSchema: { device, title: z.string() } }, async ({ device, title }) => result(await client.createScreenSession(device, title)));
  server.registerTool(operation("screen.session.list").mcp, { title: "List Paperboard screens", description: "List interactive Paperboard Screen sessions.", inputSchema: { device } }, async ({ device }) => result(await client.listScreenSessions(device)));
  server.registerTool(operation("screen.session.get").mcp, { title: "Get Paperboard screen", description: "Read an interactive Paperboard Screen session and its message history.", inputSchema: { device, session: z.string() } }, async ({ device, session }) => result(await client.getScreenSession(device, session)));
  server.registerTool(operation("screen.message.present").mcp, {
    title: "Present Paperboard Screen", description: "Present interactive content and foreground the unified Paperboard app by default. The title is already rendered as the screen heading; do not repeat it as the first Markdown heading.",
    inputSchema: { device, session: z.string(), title: z.string(), body: z.string().default(""), actions: z.array(z.unknown()).default([]), replace_key: z.string().optional(), foreground: z.boolean().default(true) },
  }, async ({ device, session, ...message }) => result(await client.presentScreen(device, session, screenMessageInputSchema.parse(message))));
  server.registerTool(operation("screen.event.list").mcp, { title: "Read Paperboard Screen interactions", description: "Read user interaction events from a screen after a cursor.", inputSchema: { device, session: z.string(), after: z.number().int().min(0).default(0) } }, async ({ device, session, after }) => result(await client.screenEvents(device, session, after)));
  server.registerTool(operation("screen.event.ack").mcp, { title: "Acknowledge Paperboard Screen interaction", description: "Acknowledge one processed Screen event.", inputSchema: { device, session: z.string(), event: z.string() } }, async ({ device, session, event }) => { await client.acknowledgeScreenEvent(device, session, event); return result({ acknowledged: event }); });
  server.registerTool(operation("screen.session.close").mcp, { title: "Close Paperboard Screen", description: "Close a Screen session without exiting the tablet app.", inputSchema: { device, session: z.string() } }, async ({ device, session }) => result(await client.closeScreenSession(device, session)));

  return server;
}
