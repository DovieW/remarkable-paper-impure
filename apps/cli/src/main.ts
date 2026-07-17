#!/usr/bin/env node
import { readFile, writeFile } from "node:fs/promises";
import { extname } from "node:path";
import { parseArgs } from "node:util";
import { PaperboardAdminClient, PaperboardClient } from "@paperboard/client";
import { screenMessageInputSchema, cardInputSchema, cardPatchSchema, clientScopeSchema, providerSchema } from "@paperboard/core";

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
  if (command === "dashboard" && rest[0] === "asset" && rest[1] === "upload") {
    const { values } = parseArgs({ args: rest.slice(2), options: { device: { type: "string" }, path: { type: "string" } }, strict: true });
    const path = required(values.path, "--path");
    const extension = extname(path).toLowerCase();
    const contentType = extension === ".jpg" || extension === ".jpeg" ? "image/jpeg" : extension === ".bmp" ? "image/bmp" : "image/png";
    output(await client().uploadAsset(required(values.device, "--device"), await readFile(path), contentType)); return;
  }
  if (command === "dashboard" && rest[0] === "show") {
    const { values } = parseArgs({ args: rest.slice(1), options: common, strict: true });
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
  if (command === "dashboard" && rest[0] === "update") {
    const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, card: { type: "string" }, title: { type: "string" }, body: { type: "string" }, progress: { type: "string" }, priority: { type: "string" }, ttl: { type: "string" }, pin: { type: "boolean" } }, strict: true });
    const patch = cardPatchSchema.parse({ title: values.title, body: values.body, progress: values.progress !== undefined ? Number(values.progress) : undefined, priority: values.priority, ttl_seconds: values.ttl ? Number(values.ttl) : undefined, pinned: values.pin });
    output(await client().update(required(values.device, "--device"), required(values.card, "--card"), patch)); return;
  }
  if (command === "dashboard" && rest[0] === "list") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" } } }); output(await client().list(required(values.device, "--device"))); return; }
  if (command === "dashboard" && rest[0] === "get") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, card: { type: "string" } } }); output(await client().get(required(values.device, "--device"), required(values.card, "--card"))); return; }
  if (command === "dashboard" && rest[0] === "delete") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, card: { type: "string" } } }); await client().delete(required(values.device, "--device"), required(values.card, "--card")); output({ deleted: values.card }); return; }
  if (command === "dashboard" && rest[0] === "clear") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" } } }); output(await client().clear(required(values.device, "--device"))); return; }
  if (command === "dashboard" && rest[0] === "wait") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, card: { type: "string" }, until: { type: "string" }, timeout: { type: "string" } } }); const until = values.until ?? "acknowledged"; if (until !== "acknowledged" && until !== "visible") throw new Error("--until must be acknowledged or visible"); output(await waitFor(required(values.device, "--device"), until, values.card, Number(values.timeout ?? 30))); return; }
  if (command === "device" && rest[0] === "status") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" } } }); output(await client().deviceStatus(required(values.device, "--device"))); return; }
  if (command === "device" && rest[0] === "apps") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" } } }); output(await client().deviceApps(required(values.device, "--device"))); return; }
  if (command === "device" && rest[0] === "launch") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, app: { type: "string" } } }); output(await client().deviceLaunch(required(values.device, "--device"), required(values.app, "--app"))); return; }
  if (command === "device" && rest[0] === "exit") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" } } }); output(await client().deviceExit(required(values.device, "--device"))); return; }
  if (command === "device" && rest[0] === "screenshot") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, output: { type: "string" } } }); const path = required(values.output, "--output"); await writeFile(path, await client().deviceScreenshot(required(values.device, "--device")), { mode: 0o600 }); output({ path }); return; }
  if (command === "device" && rest[0] === "control") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, action: { type: "string" }, wait: { type: "boolean" } } }); const created = await client().command(required(values.device, "--device"), required(values.action, "--action") as Parameters<PaperboardClient["command"]>[1]); if (!values.wait) { output(created); return; } const id = required(String(created.id ?? ""), "command id"); for (let attempt = 0; attempt < 20; attempt++) { const state = await client().commandStatus(values.device!, id); if (["completed", "failed", "expired"].includes(String(state.status))) { output(state); return; } await pause(250); } throw new Error("command did not complete"); }
  if (command === "device" && rest[0] === "command-status") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, command: { type: "string" } } }); output(await client().commandStatus(required(values.device, "--device"), required(values.command, "--command"))); return; }
  if (command === "admin" && rest[0] === "device" && rest[1] === "create") { const { values } = parseArgs({ args: rest.slice(2), options: { id: { type: "string" } } }); output(await admin().createDevice(required(values.id, "--id"))); return; }
  if (command === "admin" && rest[0] === "client" && rest[1] === "create") { const { values } = parseArgs({ args: rest.slice(2), options: { id: { type: "string" }, scope: { type: "string", multiple: true } } }); const scopes = values.scope ?? clientScopeSchema.options; output(await admin().createClient(required(values.id, "--id"), scopes)); return; }
  if (command === "admin" && rest[0] === "client" && rest[1] === "list") { output(await admin().listClients()); return; }
  if (command === "admin" && rest[0] === "client" && rest[1] === "revoke") { const { values } = parseArgs({ args: rest.slice(2), options: { id: { type: "string" } } }); output(await admin().revokeClient(required(values.id, "--id"))); return; }
  if (command === "admin" && rest[0] === "migrations") { output(await admin().migrations()); return; }
  if (command === "admin" && rest[0] === "client" && rest[1] === "scopes") { const { values } = parseArgs({ args: rest.slice(2), options: { id: { type: "string" }, scope: { type: "string", multiple: true } } }); output(await admin().updateClientScopes(required(values.id, "--id"), (values.scope ?? []) as Parameters<PaperboardAdminClient["updateClientScopes"]>[1])); return; }
  if (command === "admin" && rest[0] === "device" && rest[1] === "rotate-token") { const { values } = parseArgs({ args: rest.slice(2), options: { device: { type: "string" } } }); output(await admin().rotateDevice(required(values.device, "--device"))); return; }
  if (command === "admin" && rest[0] === "provider" && rest[1] === "set") {
    const { values } = parseArgs({ args: rest.slice(2), options: { device: { type: "string" }, kind: { type: "string" }, "base-url": { type: "string" }, "upstream-device": { type: "string" }, "access-token": { type: "string" }, "access-token-file": { type: "string" }, "allow-private-http": { type: "boolean" } } });
    if (values["access-token"] && values["access-token-file"]) throw new Error("use only one of --access-token or --access-token-file");
    const accessToken = values["access-token-file"]
      ? (await readFile(values["access-token-file"], "utf8")).trim()
      : values["access-token"];
    const provider = providerSchema.parse(values.kind === "none" ? { kind: "none" } : { kind: values.kind, base_url: values["base-url"], device_id: values["upstream-device"], access_token: accessToken, allow_private_http: values["allow-private-http"] ?? false });
    output(await admin().setProvider(required(values.device, "--device"), provider)); return;
  }
  if (command === "screen" && rest[0] === "start") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, title: { type: "string" } } }); output(await client().createScreenSession(required(values.device, "--device"), required(values.title, "--title"))); return; }
  if (command === "screen" && rest[0] === "list") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" } } }); output(await client().listScreenSessions(required(values.device, "--device"))); return; }
  if (command === "screen" && rest[0] === "status") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, session: { type: "string" } } }); output(await client().getScreenSession(required(values.device, "--device"), required(values.session, "--session"))); return; }
  if (command === "screen" && rest[0] === "present") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, session: { type: "string" }, title: { type: "string" }, body: { type: "string" }, actions: { type: "string" }, "replace-key": { type: "string" }, foreground: { type: "boolean" } } }); const actions = values.actions ? JSON.parse(values.actions) : []; output(await client().presentScreen(required(values.device, "--device"), required(values.session, "--session"), screenMessageInputSchema.parse({ title: required(values.title, "--title"), body: values.body ?? "", actions, replace_key: values["replace-key"], foreground: values.foreground ?? true }))); return; }
  if (command === "screen" && rest[0] === "events") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, session: { type: "string" }, after: { type: "string" } } }); output(await client().screenEvents(required(values.device, "--device"), required(values.session, "--session"), Number(values.after ?? 0))); return; }
  if (command === "screen" && rest[0] === "ack") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, session: { type: "string" }, event: { type: "string" } } }); await client().acknowledgeScreenEvent(required(values.device, "--device"), required(values.session, "--session"), required(values.event, "--event")); output({ acknowledged: values.event }); return; }
  if (command === "screen" && rest[0] === "close") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, session: { type: "string" } } }); output(await client().closeScreenSession(required(values.device, "--device"), required(values.session, "--session"))); return; }
  process.stderr.write("Usage: paperboard <dashboard|screen|device|admin> <operation> [options]\n");
  process.exitCode = 2;
}

main().catch((error) => { process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`); process.exitCode = 1; });
