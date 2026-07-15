#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { extname } from "node:path";
import { parseArgs } from "node:util";
import { PaperboardAdminClient, PaperboardClient } from "@paperboard/client";
import { cardInputSchema, cardPatchSchema, providerSchema } from "@paperboard/core";

const argumentsFromShell = process.argv.slice(2);
if (argumentsFromShell[0] === "--") argumentsFromShell.shift();
const [command, ...rest] = argumentsFromShell;
const baseUrl = process.env.PAPERBOARD_URL ?? "http://127.0.0.1:8787";

function required(value: string | undefined, label: string): string { if (!value) throw new Error(`${label} is required`); return value; }
function output(value: unknown): void { process.stdout.write(`${JSON.stringify(value, null, 2)}\n`); }
function client(): PaperboardClient { return new PaperboardClient({ baseUrl, token: required(process.env.PAPERBOARD_TOKEN, "PAPERBOARD_TOKEN") }); }
function admin(): PaperboardAdminClient { return new PaperboardAdminClient({ baseUrl: process.env.PAPERBOARD_ADMIN_URL ?? "http://127.0.0.1:8788", token: required(process.env.PAPERBOARD_ADMIN_TOKEN, "PAPERBOARD_ADMIN_TOKEN") }); }

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
  if (command === "clear") { const { values } = parseArgs({ args: rest, options: { device: { type: "string" } } }); output(await client().clear(required(values.device, "--device"))); return; }
  if (command === "status") { const { values } = parseArgs({ args: rest, options: { device: { type: "string" } } }); output(await client().status(required(values.device, "--device"))); return; }
  if (command === "device" && rest[0] === "create") { const { values } = parseArgs({ args: rest.slice(1), options: { id: { type: "string" } } }); output(await admin().createDevice(required(values.id, "--id"))); return; }
  if (command === "client" && rest[0] === "create") { const { values } = parseArgs({ args: rest.slice(1), options: { id: { type: "string" }, scopes: { type: "string", multiple: true } } }); output(await admin().createClient(required(values.id, "--id"), values.scopes ?? ["cards:write", "cards:clear", "status:read"])); return; }
  if (command === "token" && rest[0] === "rotate") { const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" } } }); output(await admin().rotateDevice(required(values.device, "--device"))); return; }
  if (command === "provider" && rest[0] === "set") {
    const { values } = parseArgs({ args: rest.slice(1), options: { device: { type: "string" }, kind: { type: "string" }, "base-url": { type: "string" }, "upstream-device": { type: "string" }, "access-token": { type: "string" }, "allow-private-http": { type: "boolean" } } });
    const provider = providerSchema.parse(values.kind === "none" ? { kind: "none" } : { kind: values.kind, base_url: values["base-url"], device_id: values["upstream-device"], access_token: values["access-token"], allow_private_http: values["allow-private-http"] ?? false });
    output(await admin().setProvider(required(values.device, "--device"), provider)); return;
  }
  process.stderr.write("Usage: paperboard <show|update|clear|status|device create|client create|token rotate|provider set> [options]\n");
  process.exitCode = 2;
}

main().catch((error) => { process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`); process.exitCode = 1; });
