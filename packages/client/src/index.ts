import { operationPath, type ScreenMessageInput, type CardInput, type CardPatch, type ClientScope, type OperationId, type PaperboardCommandAction, type ProviderInput } from "@paperboard/core";

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

  private path(id: OperationId, values: Record<string, string>): string { return operationPath(id, values); }

  private async requestBytes(path: string): Promise<Buffer> {
    const response = await fetch(`${this.baseUrl}${path}`, { headers: { authorization: `Bearer ${this.options.token}` } });
    if (!response.ok) throw new Error(`Paperboard HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
    return Buffer.from(await response.arrayBuffer());
  }

  async uploadAsset(device: string, bytes: Buffer, contentType: string): Promise<{ id: string; sha256: string }> {
    const body = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    return this.request(this.path("dashboard.asset.upload", { device }), { method: "POST", body, headers: { "content-type": contentType } }) as Promise<{ id: string; sha256: string }>;
  }
  async show(device: string, card: CardInput, idempotencyKey?: string): Promise<{ id: string; cursor: number }> {
    return this.request(this.path("dashboard.card.create", { device }), { method: "POST", body: JSON.stringify(card), headers: { "content-type": "application/json", ...(idempotencyKey ? { "idempotency-key": idempotencyKey } : {}) } }) as Promise<{ id: string; cursor: number }>;
  }
  async update(device: string, card: string, patch: CardPatch): Promise<{ id: string; cursor: number }> {
    return this.request(this.path("dashboard.card.update", { device, card }), { method: "PATCH", body: JSON.stringify(patch), headers: { "content-type": "application/json" } }) as Promise<{ id: string; cursor: number }>;
  }
  async delete(device: string, card: string): Promise<void> { await this.request(this.path("dashboard.card.delete", { device, card }), { method: "DELETE" }); }
  async list(device: string): Promise<{ cards: Array<Record<string, unknown>> }> { return this.request(this.path("dashboard.card.list", { device })) as Promise<{ cards: Array<Record<string, unknown>> }>; }
  async get(device: string, card: string): Promise<Record<string, unknown>> { return this.request(this.path("dashboard.card.get", { device, card })) as Promise<Record<string, unknown>>; }
  async clear(device: string): Promise<{ removed: number }> { return this.request(this.path("dashboard.clear", { device }), { method: "POST" }) as Promise<{ removed: number }>; }
  async status(device: string): Promise<Record<string, unknown>> { return this.request(this.path("device.status", { device })) as Promise<Record<string, unknown>>; }
  async deviceStatus(device: string): Promise<Record<string, unknown>> { return this.status(device); }
  async deviceApps(device: string): Promise<Record<string, unknown>> { return this.request(this.path("device.apps", { device })) as Promise<Record<string, unknown>>; }
  async deviceLaunch(device: string, appId: string): Promise<Record<string, unknown>> { return this.request(this.path("device.launch", { device }), { method: "POST", body: JSON.stringify({ app_id: appId }), headers: { "content-type": "application/json" } }) as Promise<Record<string, unknown>>; }
  async deviceExit(device: string): Promise<Record<string, unknown>> { return this.request(this.path("device.exit", { device }), { method: "POST" }) as Promise<Record<string, unknown>>; }
  async deviceScreenshot(device: string): Promise<Buffer> { return this.requestBytes(this.path("device.screenshot", { device })); }
  async command(device: string, action: PaperboardCommandAction): Promise<Record<string, unknown>> { return this.request(this.path("device.command", { device }), { method: "POST", body: JSON.stringify({ action }), headers: { "content-type": "application/json" } }) as Promise<Record<string, unknown>>; }
  async commandStatus(device: string, command: string): Promise<Record<string, unknown>> { return this.request(this.path("device.command.status", { device, command })) as Promise<Record<string, unknown>>; }
  async createScreenSession(device: string, title: string): Promise<Record<string, unknown>> { return this.request(this.path("screen.session.create", { device }), { method: "POST", body: JSON.stringify({ title }), headers: { "content-type": "application/json" } }) as Promise<Record<string, unknown>>; }
  async listScreenSessions(device: string): Promise<Record<string, unknown>> { return this.request(this.path("screen.session.list", { device })) as Promise<Record<string, unknown>>; }
  async getScreenSession(device: string, session: string): Promise<Record<string, unknown>> { return this.request(this.path("screen.session.get", { device, session })) as Promise<Record<string, unknown>>; }
  async presentScreen(device: string, session: string, message: ScreenMessageInput): Promise<Record<string, unknown>> { return this.request(this.path("screen.message.present", { device, session }), { method: "POST", body: JSON.stringify(message), headers: { "content-type": "application/json" } }) as Promise<Record<string, unknown>>; }
  async screenEvents(device: string, session: string, after = 0): Promise<Record<string, unknown>> { return this.request(`${this.path("screen.event.list", { device, session })}?after=${after}`) as Promise<Record<string, unknown>>; }
  async acknowledgeScreenEvent(device: string, session: string, event: string): Promise<void> { await this.request(this.path("screen.event.ack", { device, session, event }), { method: "POST" }); }
  async closeScreenSession(device: string, session: string): Promise<Record<string, unknown>> { return this.request(this.path("screen.session.close", { device, session }), { method: "POST" }) as Promise<Record<string, unknown>>; }
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
  async listClients(): Promise<Record<string, unknown>> {
    const response = await fetch(`${this.baseUrl}/admin/clients`, { headers: { authorization: `Bearer ${this.options.token}` } });
    if (!response.ok) throw new Error(`Paperboard admin HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
    return response.json() as Promise<Record<string, unknown>>;
  }
  async revokeClient(id: string): Promise<Record<string, unknown>> {
    const response = await fetch(`${this.baseUrl}/admin/clients/${encodeURIComponent(id)}`, { method: "DELETE", headers: { authorization: `Bearer ${this.options.token}` } });
    if (!response.ok) throw new Error(`Paperboard admin HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
    return response.json() as Promise<Record<string, unknown>>;
  }
  async migrations(): Promise<Record<string, unknown>> {
    const response = await fetch(`${this.baseUrl}/admin/migrations`, { headers: { authorization: `Bearer ${this.options.token}` } });
    if (!response.ok) throw new Error(`Paperboard admin HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
    return response.json() as Promise<Record<string, unknown>>;
  }
  async updateClientScopes(id: string, scopes: ClientScope[]): Promise<Record<string, unknown>> {
    const response = await fetch(`${this.baseUrl}/admin/clients/${encodeURIComponent(id)}/scopes`, { method: "PUT", headers: { authorization: `Bearer ${this.options.token}`, "content-type": "application/json" }, body: JSON.stringify({ scopes }) });
    if (!response.ok) throw new Error(`Paperboard admin HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
    return response.json() as Promise<Record<string, unknown>>;
  }
  rotateDevice(id: string): Promise<Record<string, unknown>> { return this.request(`/admin/devices/${encodeURIComponent(id)}/token`); }
  async setProvider(device: string, provider: ProviderInput): Promise<Record<string, unknown>> {
    const response = await fetch(`${this.baseUrl}/admin/devices/${encodeURIComponent(device)}/provider`, { method: "PUT", headers: { authorization: `Bearer ${this.options.token}`, "content-type": "application/json" }, body: JSON.stringify(provider) });
    if (!response.ok) throw new Error(`Paperboard admin HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
    return response.json() as Promise<Record<string, unknown>>;
  }
}
