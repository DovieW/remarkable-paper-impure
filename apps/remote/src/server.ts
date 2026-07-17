import { randomBytes } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { TabletController } from "./controller.js";

const SCREEN_WIDTH = 1404;
const SCREEN_HEIGHT = 1872;
const ARM_DURATION_MS = 5 * 60 * 1000;
const publicRoot = fileURLToPath(new URL("../public/", import.meta.url));

function sendJson(response: ServerResponse, status: number, value: unknown): void {
  const body = Buffer.from(JSON.stringify(value));
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": body.length,
    "cache-control": "no-store",
  });
  response.end(body);
}

async function readJson(request: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.from(chunk);
    size += buffer.length;
    if (size > 8192) throw new Error("request body is too large");
    chunks.push(buffer);
  }
  const contentType = request.headers["content-type"] ?? "";
  if (!contentType.startsWith("application/json")) throw new Error("application/json is required");
  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>;
}

function integer(value: unknown, minimum: number, maximum: number, name: string): number {
  if (!Number.isInteger(value) || Number(value) < minimum || Number(value) > maximum) {
    throw new Error(`${name} must be an integer between ${minimum} and ${maximum}`);
  }
  return Number(value);
}

export function buildRemoteServer(controller: TabletController) {
  const token = randomBytes(32).toString("base64url");
  let armedUntil = 0;

  const server = createServer(async (request, response) => {
    response.setHeader("content-security-policy", "default-src 'self'; img-src 'self' blob:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'");
    response.setHeader("x-content-type-options", "nosniff");
    response.setHeader("x-frame-options", "DENY");
    response.setHeader("referrer-policy", "no-referrer");
    const url = new URL(request.url ?? "/", "http://127.0.0.1");

    try {
      if (request.method === "GET" && url.pathname === "/api/session") {
        sendJson(response, 200, { token, armed_until: armedUntil, screen: { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } });
        return;
      }

      if (url.pathname.startsWith("/api/") && request.headers["x-paper-remote-token"] !== token) {
        sendJson(response, 403, { error: "invalid local session token" });
        return;
      }

      if (request.method === "GET" && url.pathname === "/api/status") {
        sendJson(response, 200, { ...(await controller.status()), armed_until: armedUntil });
        return;
      }
      if (request.method === "GET" && url.pathname === "/api/frame") {
        const frame = await controller.capture();
        response.writeHead(200, { "content-type": "image/png", "content-length": frame.length, "cache-control": "no-store, max-age=0" });
        response.end(frame);
        return;
      }
      if (request.method === "POST" && url.pathname === "/api/arm") {
        const body = await readJson(request);
        if (body.confirmed_unlocked !== true) throw new Error("confirm that the tablet is already unlocked");
        armedUntil = Date.now() + ARM_DURATION_MS;
        sendJson(response, 200, { armed_until: armedUntil });
        return;
      }
      if (request.method === "POST" && url.pathname === "/api/disarm") {
        await readJson(request);
        armedUntil = 0;
        sendJson(response, 200, { armed_until: armedUntil });
        return;
      }
      if (request.method === "POST" && url.pathname === "/api/input") {
        if (Date.now() >= armedUntil) {
          armedUntil = 0;
          sendJson(response, 423, { error: "input is disarmed; unlock the tablet physically and arm it again" });
          return;
        }
        const body = await readJson(request);
        if (body.action === "tap") {
          await controller.tap(integer(body.x, 0, SCREEN_WIDTH - 1, "x"), integer(body.y, 0, SCREEN_HEIGHT - 1, "y"));
        } else if (body.action === "swipe") {
          await controller.swipe(
            integer(body.x1, 0, SCREEN_WIDTH - 1, "x1"), integer(body.y1, 0, SCREEN_HEIGHT - 1, "y1"),
            integer(body.x2, 0, SCREEN_WIDTH - 1, "x2"), integer(body.y2, 0, SCREEN_HEIGHT - 1, "y2"),
            integer(body.duration_ms, 100, 5000, "duration_ms"),
          );
        } else {
          throw new Error("unsupported input action");
        }
        sendJson(response, 200, { accepted: true, armed_until: armedUntil });
        return;
      }
      if (request.method === "POST" && url.pathname === "/api/control") {
        const body = await readJson(request);
        if (body.action !== "paperboard" && body.action !== "canvas" && body.action !== "exit") throw new Error("unsupported control action");
        const result = await controller.control(body.action);
        if (body.action === "exit") armedUntil = 0;
        sendJson(response, 200, { result, armed_until: armedUntil });
        return;
      }

      if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/app.css" || url.pathname === "/app.js")) {
        const name = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
        const path = resolve(publicRoot, name);
        const body = await readFile(path);
        const types: Record<string, string> = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8" };
        response.writeHead(200, { "content-type": types[extname(path)] ?? "application/octet-stream", "content-length": body.length, "cache-control": "no-store" });
        response.end(body);
        return;
      }

      sendJson(response, 404, { error: "not found" });
    } catch (error) {
      sendJson(response, 400, { error: error instanceof Error ? error.message : "request failed" });
    }
  });

  server.on("close", () => { void controller.close(); });
  return { server, token };
}
