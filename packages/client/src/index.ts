import type { CardInput, CardPatch, ProviderInput } from "@paperboard/core";

export interface PaperboardClientOptions { baseUrl: string; token: string; }

export class PaperboardClient {
  private readonly baseUrl: string;
  constructor(private readonly options: PaperboardClientOptions) {
    this.baseUrl = options.baseUrl.replace(/\/$/, "");
  }

  private async request(path: string, init: RequestInit = {}): Promise<unknown> {
    const response = await fetch(`${this.baseUrl}${path}`, {
      ...init,
      headers: { authorization: `Bearer ${this.options.token}`, ...init.headers },
    });
    if (!response.ok) {
      const detail = await response.text();
      throw new Error(`Paperboard HTTP ${response.status}: ${detail.slice(0, 500)}`);
    }
    if (response.status === 204) return undefined;
    return response.json();
  }

  async uploadAsset(device: string, bytes: Buffer, contentType: string): Promise<{ id: string; sha256: string }> {
    const body = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    return this.request(`/v1/devices/${encodeURIComponent(device)}/assets`, { method: "POST", body, headers: { "content-type": contentType } }) as Promise<{ id: string; sha256: string }>;
  }
  async show(device: string, card: CardInput, idempotencyKey?: string): Promise<{ id: string; cursor: number }> {
    return this.request(`/v1/devices/${encodeURIComponent(device)}/cards`, { method: "POST", body: JSON.stringify(card), headers: { "content-type": "application/json", ...(idempotencyKey ? { "idempotency-key": idempotencyKey } : {}) } }) as Promise<{ id: string; cursor: number }>;
  }
  async update(device: string, card: string, patch: CardPatch): Promise<{ id: string; cursor: number }> {
    return this.request(`/v1/devices/${encodeURIComponent(device)}/cards/${encodeURIComponent(card)}`, { method: "PATCH", body: JSON.stringify(patch), headers: { "content-type": "application/json" } }) as Promise<{ id: string; cursor: number }>;
  }
  async delete(device: string, card: string): Promise<void> { await this.request(`/v1/devices/${encodeURIComponent(device)}/cards/${encodeURIComponent(card)}`, { method: "DELETE" }); }
  async clear(device: string): Promise<{ removed: number }> { return this.request(`/v1/devices/${encodeURIComponent(device)}/clear`, { method: "POST" }) as Promise<{ removed: number }>; }
  async status(device: string): Promise<Record<string, unknown>> { return this.request(`/v1/devices/${encodeURIComponent(device)}/status`) as Promise<Record<string, unknown>>; }
}

export class PaperboardAdminClient {
  private readonly baseUrl: string;
  constructor(private readonly options: PaperboardClientOptions) { this.baseUrl = options.baseUrl.replace(/\/$/, ""); }
  private async request(path: string, body?: unknown): Promise<Record<string, unknown>> {
    const init: RequestInit = { method: "POST", headers: { authorization: `Bearer ${this.options.token}`, "content-type": "application/json" } };
    if (body !== undefined) init.body = JSON.stringify(body);
    const response = await fetch(`${this.baseUrl}${path}`, init);
    if (!response.ok) throw new Error(`Paperboard admin HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
    return response.json() as Promise<Record<string, unknown>>;
  }
  createDevice(id: string): Promise<Record<string, unknown>> { return this.request("/admin/devices", { id }); }
  createClient(id: string, scopes: string[]): Promise<Record<string, unknown>> { return this.request("/admin/clients", { id, scopes }); }
  rotateDevice(id: string): Promise<Record<string, unknown>> { return this.request(`/admin/devices/${encodeURIComponent(id)}/token`); }
  async setProvider(device: string, provider: ProviderInput): Promise<Record<string, unknown>> {
    const response = await fetch(`${this.baseUrl}/admin/devices/${encodeURIComponent(device)}/provider`, { method: "PUT", headers: { authorization: `Bearer ${this.options.token}`, "content-type": "application/json" }, body: JSON.stringify(provider) });
    if (!response.ok) throw new Error(`Paperboard admin HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
    return response.json() as Promise<Record<string, unknown>>;
  }
}
