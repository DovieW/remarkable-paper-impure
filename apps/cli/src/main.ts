#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { extname } from "node:path";
import { parseArgs } from "node:util";
import { PaperboardAdminClient, PaperboardClient } from "@paperboard/client";
import { canvasMessageInputSchema, cardInputSchema, cardPatchSchema, providerSchema } from "@paperboard/core";

const argumentsFromShell = process.argv.slice(2);
if (argumentsFromShell[0] === "--") argumentsFromShell.shift();
const [command, ...rest] = argumentsFromShell;
const baseUrl = process.env.PAPERBOARD_URL ?? "http://127.0.0.1:8787";

function required(value: string | undefined, label: string): string { if (!value) throw new Error(`${label} is required`); return value; }
function output(value: unknown): void { process.stdout.write(`${JSON.stringify(value, null, 2)}\n`); }
function client(): PaperboardClient { return new PaperboardClient({ baseUrl, token: required(process.env.PAPERBOARD_TOKEN, "PAPERBOARD_TOKEN") }); }
function admin(): PaperboardAdminClient { return new PaperboardAdminClient({ baseUrl: process.env.PAPERBOARD_ADMIN_URL ?? "http://127.0.0.1:8788", token: required(process.env.PAPERBOARD_ADMIN_TOKEN, "PAPERBOARD_ADMIN_TOKEN") }); }
const pause = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function waitFor(device: string, target: "acknowledged" | "visible", card: string | undefined, timeoutSeconds: number): Promise<Record<string, unknown>> {
  const deadline = Date.now() + timeoutSeconds * 1000;
  while (Date.now() < deadline) {
    const state = await client().status(device);
    const visible = state.visible_card as { id?: string } | null | undefined;
    if (target === "visible" && visible?.id && (!card || visible.id === card)) return state;
    const item = card ? await client().get(device, card).catch(() => undefined) as { cursor?: number } | undefined : undefined;
    if (target === "acknowledged" && item?.cursor !== undefined && Number(state.last_ack_cursor ?? 0) >= item.cursor) return state;
    await pause(1000);
  }
  throw new Error(`timed out waiting for ${target}`);
}

const common = {
  device: { type: "string" as const }, title: { type: "string" as const }, body: { type: "string" as const },
  priority: { type: "string" as const }, ttl: { type: "string" as const }, pin: { type: "boolean" as const },
  "replace-key": { type: "string" as const }, image: { type: "string" as const }, progress: { type: "string" as const },
};

async function main(): Promise<void> {
  if (command === "show") {
    const { values } = parseArgs({ args: rest, options: common, strict: true });
    const device = required(values.device, "--device");
    let assetId: string | undefined;
    if (values.image) {
      const extension = extname(values.image).toLowerCase();
      const contentType = extension === ".jpg" || extension === ".jpeg" ? "image/jpeg" : extension === ".bmp" ? "image/bmp" : "image/png";
      assetId = (await client().uploadAsset(device, await readFile(values.image), contentType)).id;
    }
    const card = cardInputSchema.parse({ kind: assetId ? "image" : values.progress !== undefined ? "progress" : "message", title: required(values.title, "--title"), body: values.body ?? "", progress: values.progress !== undefined ? Number(values.progress) : undefined, asset_id: assetId, priority: values.priority ?? "normal", ttl_seconds: values.ttl ? Number(values.ttl) : 300, pinned: values.pin ?? false, replace_key: values["replace-key"] });
    output(await client().show(device, card, crypto.randomUUID()));
    return;
  }
  if (command === "update") {
    const { values } = parseArgs({ args: rest, options: { device: { type: "string" }, card: { type: "string" }, title: { type: "string" }, body: { type: "string" }, progress: { type: "string" }, priority: { type: "string" }, ttl: { type: "string" }, pin: { type: "boolean" } }, strict: true });
    const patch = cardPatchSchema.parse({ title: values.title, body: values.body, progress: values.progress !== undefined ? Number(values.progress) : undefined, priority: values.priority, ttl_seconds: values.ttl ? Number(values.ttl) : undefined, pinned: values.pin });
    output(await client().update(required(values.device, "--device"), required(values.card, "--card"), patch)); return;
  }
  if (command === "list") { const { values } = parseArgs({ args: rest, options: { device: { type: "string" } } }); output(await client().list(required(values.device, "--device"))); return; }
  if (command === "get") { const { values } = parseArgs({ args: rest, options: { device: { type: "string" }, card: { type: "string" } } }); output(await client().get(required(values.device, "--device"), required(values.card, "--card"))); return; }
  if (command === "delete") { const { values } = parseArgs({ args: rest, options: { device: { type: "string" }, card: { type: "string" } } }); await client().delete(required(values.device, "--device"), required(values.card, "--card")); output({ deleted: values.card }); return; }
  if (command === "clear") { const { values } = parseArgs({ args: rest, options: { device: { type: "string" } } }); output(await client().clear(required(values.device, "--device"))); return; }
  if (command === "status") { const { values } = parseArgs({ args: rest, options: { device: { type: "string" } } }); output(await client().status(required(values.device, "--device"))); return; }
  if (command === "wait") { const { values } = parseArgs({ args: rest, options: { device: { type: "string" }, card: { type: "string" }, until: { type: "string" }, timeout: { type: "string" } } }); const until = values.until ?? "acknowledged"; if (until !== "acknowledged" && until !== "visible") throw new Error("--until must be acknowledged or visible"); output(await waitFor(required(values.device, "--device"), until, values.card, Number(values.timeout ?? 30))); return; }
  if (command === "control") { const { values } = parseArgs({ args: rest, options: { device: { type: "string" }, action: { type: "string" }, wait: { type: "boolean" } } }); const created = await client().command(required(values.device, "--device"), required(values.action, "--action") as Parameters<PaperboardClient["command"]>[1]); if (!values.wait) { output(created); return; } const id = required(String(created.id ?? ""), "command id"); for (let attempt = 0; attempt < 20; attempt++) { const state = await client().commandStatus(values.device!, id); if (["completed", "failed", "expired"].includes(String(state.status))) { output(state); return; } await pause(250); } throw new Error("command did not complete"); }
  if (command === "device" && rest[0] === "create") { const { values } = parseArgs({ args: rest.slice(1), options: { id: { type: "string" } } }); output(await admin().createDevice(required(values.id, "--id"))); return; }
  if (command === "client" && rest[0] === "create") { const { values } = parseArgs({ args: rest.slice(1), options: { id: { type: "string" }, scopes: { type: "string", multiple: true } } }); output(await admin().createClient(required(values.id, "--id"), values.scopes ?? ["cards:read", "cards:write", "cards:clear", "status:read", "paperboard:control", "canvas:read", "canvas:write"])); return; }
  if (command === "client" && rest[0] === "scopes") { const { values } = parseArgs({ args: rest.slice(1), options: { id: { type: "string" }, scope: { type: "string", multiple: true } } }); output(await admin().updateClientScopes(required(values.id, "--id"), (values.scope ?? []) as Parameters<PaperboardAdminClient["updateClientScopes"]>[1])); return; }
  if (command === "token" && rest[0] === "rotate") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" } } }); output(await admin().rotateDevice(required(values.device, "--device"))); return; }
  if (command === "provider" && rest[0] === "set") {
    const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, kind: { type: "string" }, "base-url": { type: "string" }, "upstream-device": { type: "string" }, "access-token": { type: "string" }, "access-token-file": { type: "string" }, "allow-private-http": { type: "boolean" } } });
    if (values["access-token"] && values["access-token-file"]) throw new Error("use only one of --access-token or --access-token-file");
    const accessToken = values["access-token-file"]
      ? (await readFile(values["access-token-file"], "utf8")).trim()
      : values["access-token"];
    const provider = providerSchema.parse(values.kind === "none" ? { kind: "none" } : { kind: values.kind, base_url: values["base-url"], device_id: values["upstream-device"], access_token: accessToken, allow_private_http: values["allow-private-http"] ?? false });
    output(await admin().setProvider(required(values.device, "--device"), provider)); return;
  }
  if (command === "canvas" && rest[0] === "start") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, title: { type: "string" } } }); output(await client().createCanvasSession(required(values.device, "--device"), required(values.title, "--title"))); return; }
  if (command === "canvas" && rest[0] === "list") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" } } }); output(await client().listCanvasSessions(required(values.device, "--device"))); return; }
  if (command === "canvas" && rest[0] === "status") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, session: { type: "string" } } }); output(await client().getCanvasSession(required(values.device, "--device"), required(values.session, "--session"))); return; }
  if (command === "canvas" && rest[0] === "send") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, session: { type: "string" }, title: { type: "string" }, body: { type: "string" }, actions: { type: "string" }, "replace-key": { type: "string" } } }); const actions = values.actions ? JSON.parse(values.actions) : []; output(await client().sendCanvasMessage(required(values.device, "--device"), required(values.session, "--session"), canvasMessageInputSchema.parse({ title: required(values.title, "--title"), body: values.body ?? "", actions, replace_key: values["replace-key"] }))); return; }
  if (command === "canvas" && rest[0] === "events") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, session: { type: "string" }, after: { type: "string" } } }); output(await client().canvasEvents(required(values.device, "--device"), required(values.session, "--session"), Number(values.after ?? 0))); return; }
  if (command === "canvas" && rest[0] === "ack") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, session: { type: "string" }, event: { type: "string" } } }); await client().acknowledgeCanvasEvent(required(values.device, "--device"), required(values.session, "--session"), required(values.event, "--event")); output({ acknowledged: values.event }); return; }
  if (command === "canvas" && rest[0] === "close") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, session: { type: "string" } } }); output(await client().closeCanvasSession(required(values.device, "--device"), required(values.session, "--session"))); return; }
  process.stderr.write("Usage: paperboard <show|update|list|get|delete|clear|status|wait|control|canvas|device create|client create|client scopes|token rotate|provider set> [options]\n");
  process.exitCode = 2;
}

main().catch((error) => { process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`); process.exitCode = 1; });
