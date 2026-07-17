import { execFile, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, readFile, rm, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

export interface TabletStatus {
  platform: string;
  architecture: string;
  foreground: string;
  lock_state: string;
  screenshot: boolean;
  input_helper: boolean;
}

export interface TabletController {
  capture(): Promise<Buffer>;
  status(): Promise<TabletStatus>;
  tap(x: number, y: number): Promise<void>;
  swipe(x1: number, y1: number, x2: number, y2: number, durationMs: number): Promise<void>;
  control(action: "paperboard" | "canvas" | "exit"): Promise<unknown>;
  close(): Promise<void>;
}

export class SshTabletController implements TabletController {
  readonly #host: string;
  readonly #temporaryDirectoryPromise: Promise<string>;
  #captureInFlight: Promise<Buffer> | null = null;
  #inputProcess: ChildProcessWithoutNullStreams | null = null;
  #inputReady: Promise<void> | null = null;
  #inputQueue: Promise<void> = Promise.resolve();
  #pendingInput: { resolve: () => void; reject: (error: Error) => void } | null = null;
  #inputError = "";

  constructor(host = "remarkable-usb") {
    if (!/^[a-zA-Z0-9_.-]{1,128}$/.test(host)) throw new Error("invalid SSH host alias");
    this.#host = host;
    this.#temporaryDirectoryPromise = mkdtemp(join(tmpdir(), "paper-remote-"));
    /* Pay the Qt input-discovery cost before the owner sends the first tap. */
    void this.#ensureInputChannel().catch(() => undefined);
  }

  capture(): Promise<Buffer> {
    if (!this.#captureInFlight) {
      this.#captureInFlight = this.#capture().finally(() => { this.#captureInFlight = null; });
    }
    return this.#captureInFlight;
  }

  async #capture(): Promise<Buffer> {
    const directory = await this.#temporaryDirectoryPromise;
    const output = join(directory, "current.png");
    await execFileAsync(join(repositoryRoot, "scripts/paperctl.sh"), ["screenshot", output], {
      env: { ...process.env, REMARKABLE_HOST: this.#host }, timeout: 15_000,
    });
    try { return await readFile(output); }
    finally { await unlink(output).catch(() => undefined); }
  }

  async status(): Promise<TabletStatus> {
    const { stdout } = await execFileAsync(join(repositoryRoot, "scripts/tablet-companion.sh"), ["status"], {
      env: { ...process.env, REMARKABLE_HOST: this.#host }, timeout: 15_000,
    });
    return JSON.parse(stdout) as TabletStatus;
  }

  async tap(x: number, y: number): Promise<void> {
    await this.#queueInput(`tap ${x} ${y}`);
  }

  async swipe(x1: number, y1: number, x2: number, y2: number, durationMs: number): Promise<void> {
    await this.#queueInput(`swipe ${x1} ${y1} ${x2} ${y2} ${durationMs}`);
  }

  #queueInput(command: string): Promise<void> {
    const operation = this.#inputQueue.then(() => this.#sendInput(command));
    this.#inputQueue = operation.catch(() => undefined);
    return operation;
  }

  async #sendInput(command: string): Promise<void> {
    await this.#ensureInputChannel();
    const process = this.#inputProcess;
    if (!process || !process.stdin.writable) throw new Error("tablet input channel is unavailable");
    if (this.#pendingInput) throw new Error("tablet input channel is busy");
    await new Promise<void>((resolve, reject) => {
      this.#pendingInput = { resolve, reject };
      process.stdin.write(`${command}\n`, error => {
        if (!error) return;
        this.#pendingInput = null;
        reject(error);
      });
    });
  }

  #ensureInputChannel(): Promise<void> {
    if (this.#inputReady) return this.#inputReady;
    this.#inputError = "";
    const process = spawn("ssh", [
      "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", this.#host,
      "/home/root/.local/bin/paperctl-tap", "--serve",
    ]);
    this.#inputProcess = process;
    process.stderr.setEncoding("utf8");
    process.stderr.on("data", chunk => { this.#inputError = `${this.#inputError}${String(chunk)}`.slice(-2048); });

    this.#inputReady = new Promise<void>((resolveReady, rejectReady) => {
      let ready = false;
      const lines = createInterface({ input: process.stdout });
      lines.on("line", line => {
        if (!ready && line === "READY") { ready = true; resolveReady(); return; }
        if (line === "OK" && this.#pendingInput) {
          const pending = this.#pendingInput;
          this.#pendingInput = null;
          pending.resolve();
        }
      });
      process.once("error", error => { if (!ready) rejectReady(error); });
      process.once("exit", code => {
        const error = new Error(this.#inputError.trim() || `tablet input channel exited with status ${code ?? "unknown"}`);
        if (!ready) rejectReady(error);
        this.#pendingInput?.reject(error);
        this.#pendingInput = null;
        this.#inputProcess = null;
        this.#inputReady = null;
      });
    });
    return this.#inputReady;
  }

  async control(action: "paperboard" | "canvas" | "exit"): Promise<unknown> {
    const command = action === "exit"
      ? "paperboard-control return"
      : `paperboard-control launch ${action}`;
    const remote = `SSH_ORIGINAL_COMMAND='${command}' /home/root/.local/bin/paperboard-control`;
    const { stdout } = await execFileAsync("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", this.#host, remote], { timeout: 15_000 });
    return JSON.parse(stdout);
  }

  async close(): Promise<void> {
    const process = this.#inputProcess;
    if (process) {
      process.stdin.end();
      await Promise.race([once(process, "exit"), new Promise(resolve => setTimeout(resolve, 2000))]);
      if (!process.killed) process.kill("SIGTERM");
    }
    const directory = await this.#temporaryDirectoryPromise;
    await rm(directory, { recursive: true, force: true });
  }
}
