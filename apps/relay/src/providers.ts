import { decryptSecret, encryptSecret, providerSchema, type ProviderInput } from "@paperboard/core";
import type { Store } from "./store.js";
import { fetchImage, normalizeImage, validateUpstreamUrl } from "./images.js";
import { randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";

type DisplayResponse = { image_url?: unknown; status?: unknown; refresh_rate?: unknown };

export class ProviderManager {
  private timer?: NodeJS.Timeout;
  private running = false;

  constructor(private readonly store: Store, private readonly masterKey: Buffer, private readonly publicBaseUrl: string) {}

  set(deviceId: string, input: ProviderInput): boolean {
    const parsed = providerSchema.parse(input);
    const encrypted = parsed.kind === "none" ? null : encryptSecret(JSON.stringify(parsed), this.masterKey);
    return this.store.setProvider(deviceId, parsed.kind, encrypted);
  }

  start(): void {
    this.timer = setInterval(() => void this.tick(), 60_000);
    this.timer.unref();
    void this.tick();
  }

  stop(): void { if (this.timer) clearInterval(this.timer); }

  async tick(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try {
      const devices = this.store.db.prepare("SELECT id FROM devices WHERE provider_kind!='none'").all() as { id: string }[];
      for (const device of devices) {
        try { await this.pollDevice(device.id); }
        catch (error) { console.error(JSON.stringify({ level: "warn", event: "provider_poll_failed", device: device.id, error: String(error) })); }
      }
    } finally { this.running = false; }
  }

  async pollDevice(deviceId: string): Promise<void> {
    const stored = this.store.getProvider(deviceId);
    if (!stored || stored.kind === "none" || !stored.encryptedConfig) return;
    const provider = providerSchema.parse(JSON.parse(decryptSecret(stored.encryptedConfig, this.masterKey)));
    if (provider.kind === "none") return;
    const base = provider.base_url.replace(/\/$/, "");
    const displayUrl = `${base}/api/display`;
    await validateUpstreamUrl(displayUrl, provider.kind === "terminus" && provider.allow_private_http);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10_000);
    let response: Response;
    try {
      response = await fetch(displayUrl, {
        redirect: "error", signal: controller.signal,
        headers: {
          accept: "application/json",
          ID: provider.device_id,
          ...(provider.access_token ? { "access-token": provider.access_token } : {}),
        },
      });
    } finally { clearTimeout(timeout); }
    if (!response.ok) throw new Error(`display API returned HTTP ${response.status}`);
    const payload = await response.json() as DisplayResponse;
    if (typeof payload.image_url !== "string") throw new Error("display API response omitted image_url");
    let imageUrl = payload.image_url;
    if (provider.kind === "terminus") {
      const advertised = new URL(payload.image_url);
      imageUrl = new URL(`${advertised.pathname}${advertised.search}`, `${base}/`).toString();
    }
    const input = await fetchImage(imageUrl, undefined, provider.kind === "terminus" && provider.allow_private_http);
    const normalized = await normalizeImage(input);
    const previous = this.store.db.prepare("SELECT sha256 FROM assets WHERE device_id=? ORDER BY created_at DESC LIMIT 1").get(deviceId) as { sha256: string } | undefined;
    if (previous?.sha256 === normalized.sha256) return;
    const assetId = randomUUID().replaceAll("-", "");
    const path = this.store.newAssetPath(assetId);
    writeFileSync(path, normalized.png, { mode: 0o600, flag: "wx" });
    const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
    this.store.putAsset(deviceId, assetId, path, normalized.sha256, expiresAt);
    this.store.createCard(deviceId, {
      kind: "image", title: "Ambient dashboard", body: "", asset_id: assetId,
      priority: "ambient", ttl_seconds: 86_400, pinned: false, replace_key: "__ambient_provider__",
    });
  }
}
