import { lookup } from "node:dns/promises";
import { request } from "node:https";
import { isIP } from "node:net";

const MAX_BYTES = 2 * 1024 * 1024;
const MAX_REDIRECTS = 3;

function privateAddress(address: string): boolean {
  const normalized = address.toLowerCase();
  if (normalized === "::1" || normalized === "0.0.0.0" || normalized.startsWith("fe80:") || normalized.startsWith("fc") || normalized.startsWith("fd")) return true;
  if (isIP(address) === 4) {
    const [a, b] = address.split(".").map(Number);
    if (a === undefined || b === undefined) return true;
    return a === 0 || a === 10 || a === 127 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || a >= 224;
  }
  return false;
}

interface SafeDestination { url: URL; address: string; family: 4 | 6; }

async function assertPublicHttps(value: string): Promise<SafeDestination> {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password || url.port) throw new Error("reader accepts public HTTPS URLs without credentials or custom ports");
  const addresses = await lookup(url.hostname, { all: true, verbatim: true });
  if (!addresses.length || addresses.some(({ address }) => privateAddress(address))) throw new Error("reader destination is not public");
  const selected = addresses[0]!;
  return { url, address: selected.address, family: selected.family as 4 | 6 };
}

async function get(destination: SafeDestination): Promise<{ status: number; headers: import("node:http").IncomingHttpHeaders; bytes: Buffer }> {
  return new Promise((resolve, reject) => {
    const pending = request(destination.url, {
      method: "GET",
      servername: destination.url.hostname,
      headers: { accept: "text/html,text/plain;q=0.9", "user-agent": "PaperboardReader/2" },
      lookup: (_hostname, _options, callback) => callback(null, destination.address, destination.family),
    }, (response) => {
      const chunks: Buffer[] = [];
      let size = 0;
      response.on("data", (chunk: Buffer) => {
        size += chunk.length;
        if (size > MAX_BYTES) {
          response.destroy(new Error("reader response is too large"));
          return;
        }
        chunks.push(Buffer.from(chunk));
      });
      response.on("end", () => resolve({ status: response.statusCode ?? 0, headers: response.headers, bytes: Buffer.concat(chunks) }));
      response.on("error", reject);
    });
    pending.setTimeout(10_000, () => pending.destroy(new Error("reader request timed out")));
    pending.on("error", reject);
    pending.end();
  });
}

function decodeEntities(value: string): string {
  return value.replaceAll(/&nbsp;/gi, " ").replaceAll(/&amp;/gi, "&").replaceAll(/&lt;/gi, "<").replaceAll(/&gt;/gi, ">").replaceAll(/&quot;/gi, '"').replaceAll(/&#39;/gi, "'");
}

function simplify(html: string): { title: string; body: string } {
  const titleMatch = /<title\b[^>]*>([\s\S]*?)<\/title>/i.exec(html);
  const cleaned = html
    .replace(/<(script|style|noscript|svg|iframe|form)\b[^>]*>[\s\S]*?<\/\1>/gi, " ")
    .replace(/<(br|\/p|\/div|\/li|\/h[1-6]|\/article|\/section)>/gi, "\n")
    .replace(/<[^>]+>/g, " ");
  const body = decodeEntities(cleaned).replace(/[\t\r ]+/g, " ").replace(/ *\n */g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  const title = decodeEntities((titleMatch?.[1] ?? "Web reader").replace(/<[^>]+>/g, " ")).trim().slice(0, 160) || "Web reader";
  return { title, body: body.slice(0, 40_000) };
}

export async function fetchReaderPage(value: string): Promise<{ url: string; title: string; body: string }> {
  let destination = await assertPublicHttps(value);
  for (let redirect = 0; redirect <= MAX_REDIRECTS; redirect++) {
    const response = await get(destination);
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.location;
      if (!location || redirect === MAX_REDIRECTS) throw new Error("reader redirect limit exceeded");
      destination = await assertPublicHttps(new URL(location, destination.url).toString());
      continue;
    }
    if (response.status < 200 || response.status >= 300) throw new Error(`reader upstream returned HTTP ${response.status}`);
    const contentType = response.headers["content-type"]?.split(";", 1)[0]?.trim().toLowerCase();
    if (contentType !== "text/html" && contentType !== "text/plain") throw new Error("reader supports HTML and plain text only");
    const declared = Number(response.headers["content-length"] ?? 0);
    if (declared > MAX_BYTES) throw new Error("reader response is too large");
    const text = response.bytes.toString("utf8");
    const page = contentType === "text/plain" ? { title: destination.url.hostname, body: text.slice(0, 40_000) } : simplify(text);
    return { url: destination.url.toString(), ...page };
  }
  throw new Error("reader failed");
}
