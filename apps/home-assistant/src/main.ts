import { readFile } from "node:fs/promises";
import { PaperboardClient } from "@paperboard/client";
import { classify } from "./policy.js";

const required = (value: string | undefined, name: string): string => { if (!value) throw new Error(`${name} is required`); return value; };
const relay = new PaperboardClient({ baseUrl: process.env.PAPERBOARD_URL ?? "http://127.0.0.1:8787", token: required(process.env.PAPERBOARD_TOKEN, "PAPERBOARD_TOKEN") });
const device = required(process.env.PAPERBOARD_DEVICE, "PAPERBOARD_DEVICE");
const session = required(process.env.PAPERBOARD_SCREEN_SESSION, "PAPERBOARD_SCREEN_SESSION");
const haUrl = required(process.env.HA_URL, "HA_URL").replace(/\/$/, "");
const haToken = (await readFile(required(process.env.HA_TOKEN_FILE, "HA_TOKEN_FILE"), "utf8")).trim();
type AllowedAction = { domain: string; service: string; entity_id: string };
const allowlist = JSON.parse(await readFile(required(process.env.HA_ALLOWLIST_FILE, "HA_ALLOWLIST_FILE"), "utf8")) as Record<string, AllowedAction>;
let cursor = 0;

for (;;) {
  const response = await relay.screenEvents(device, session, cursor) as { events?: Array<{ id: string; cursor: number; action_id: string; value: unknown }> };
  for (const event of response.events ?? []) {
    cursor = Math.max(cursor, event.cursor);
    const action = allowlist[event.action_id];
    if (!action) throw new Error(`Home Assistant action is not allowlisted: ${event.action_id}`);
    const risk = classify(action.domain, action.service);
    if (risk === "denied") throw new Error(`Home Assistant action is denied: ${event.action_id}`);
    if (risk === "confirm" && event.value !== "confirmed") continue;
    const result = await fetch(`${haUrl}/api/services/${action.domain}/${action.service}`, { method: "POST", headers: { Authorization: `Bearer ${haToken}`, "Content-Type": "application/json" }, body: JSON.stringify({ entity_id: action.entity_id }) });
    if (!result.ok) throw new Error(`Home Assistant returned ${result.status}`);
    await relay.acknowledgeScreenEvent(device, session, event.id);
  }
  await new Promise((resolve) => setTimeout(resolve, 1000));
}
