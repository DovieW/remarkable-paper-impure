import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { tabletAppIdSchema } from "@paperboard/core";

const execFileAsync = promisify(execFile);
const MAX_JSON_BYTES = 256 * 1024;
const MAX_SCREENSHOT_BYTES = 16 * 1024 * 1024;

export class TabletBridge {
  constructor(private readonly command?: string) {}

  private executable(): string {
    if (!this.command) throw new Error("tablet bridge is not configured");
    return this.command;
  }

  private async json(device: string, args: string[]): Promise<Record<string, unknown>> {
    const { stdout } = await execFileAsync(this.executable(), [device, ...args], {
      encoding: "utf8", timeout: 20_000, maxBuffer: MAX_JSON_BYTES,
      env: { PATH: process.env.PATH ?? "/usr/bin:/bin" },
    });
    const parsed: unknown = JSON.parse(stdout);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error("tablet bridge returned invalid JSON");
    return parsed as Record<string, unknown>;
  }

  status(device: string): Promise<Record<string, unknown>> { return this.json(device, ["status"]); }
  apps(device: string): Promise<Record<string, unknown>> { return this.json(device, ["apps"]); }
  launch(device: string, appId: string): Promise<Record<string, unknown>> {
    return this.json(device, ["launch", tabletAppIdSchema.parse(appId)]);
  }
  return(device: string): Promise<Record<string, unknown>> { return this.json(device, ["return"]); }

  async screenshot(device: string): Promise<Buffer> {
    const { stdout } = await execFileAsync(this.executable(), [device, "screenshot"], {
      encoding: "buffer", timeout: 30_000, maxBuffer: MAX_SCREENSHOT_BYTES,
      env: { PATH: process.env.PATH ?? "/usr/bin:/bin" },
    });
    const bytes = Buffer.from(stdout);
    if (bytes.length < 8 || bytes.subarray(0, 8).toString("hex") !== "89504e470d0a1a0a") throw new Error("tablet bridge did not return a PNG");
    return bytes;
  }
}
