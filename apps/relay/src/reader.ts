import { lookup } from "node:dns/promises";
import type { IncomingHttpHeaders } from "node:http";
import { request } from "node:https";
import { isPrivateAddress } from "./images.js";

const MAX_BYTES = 2 * 1024 * 1024;
const MAX_REDIRECTS = 3;
const MAX_LINKS = 48;

export interface ReaderLink { label: string; url: string; }
export interface ReaderPage { url: string; title: string; body: string; links: ReaderLink[]; }
interface SafeDestination { url: URL; address: string; family: 4 | 6; }
interface ReaderResponse { status: number; headers: IncomingHttpHeaders; bytes: Buffer; }
interface ReaderDependencies {
  lookup: typeof lookup;
  get: (destination: SafeDestination) => Promise<ReaderResponse>;
}

export function normalizeReaderInput(value: string): string {
  const input = value.trim();
  if (!input || input.length > 2048) throw new Error("enter a web address or search term");
  if (/^https:\/\//i.test(input)) return input;
  if (/^[a-z0-9](?:[a-z0-9-]*\.)+[a-z]{2,}(?:[/?#].*)?$/i.test(input)) return `https://${input}`;
  return `https://lite.duckduckgo.com/lite/?q=${encodeURIComponent(input)}`;
}

async function assertPublicHttps(value: string, resolve: typeof lookup): Promise<SafeDestination> {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password || url.port) throw new Error("reader accepts public HTTPS URLs without credentials or custom ports");
  const addresses = await resolve(url.hostname, { all: true, verbatim: true });
  if (!addresses.length || addresses.some(({ address }) => isPrivateAddress(address))) throw new Error("reader destination is not public");
  const selected = addresses[0]!;
  return { url, address: selected.address, family: selected.family as 4 | 6 };
}

async function networkGet(destination: SafeDestination): Promise<ReaderResponse> {
  return new Promise((resolve, reject) => {
    const pending = request(destination.url, {
      method: "GET",
      servername: destination.url.hostname,
      headers: { accept: "text/html,text/plain;q=0.9", "user-agent": "PaperboardReader/2" },
      lookup: (_hostname, options, callback) => {
        if (options.all) callback(null, [{ address: destination.address, family: destination.family }]);
        else callback(null, destination.address, destination.family);
      },
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
  const codePoint = (raw: string, radix: number) => {
    const parsed = Number.parseInt(raw, radix);
    return Number.isInteger(parsed) && parsed >= 0 && parsed <= 0x10ffff ? String.fromCodePoint(parsed) : "�";
  };
  return value
    .replace(/&#(\d+);/g, (_match, decimal: string) => codePoint(decimal, 10))
    .replace(/&#x([0-9a-f]+);/gi, (_match, hexadecimal: string) => codePoint(hexadecimal, 16))
    .replaceAll(/&nbsp;/gi, " ").replaceAll(/&amp;/gi, "&").replaceAll(/&lt;/gi, "<")
    .replaceAll(/&gt;/gi, ">").replaceAll(/&quot;/gi, '"').replaceAll(/&#39;|&apos;/gi, "'");
}

function plainText(value: string): string {
  return decodeEntities(value.replace(/<[^>]+>/g, " ")).replace(/[\t\r\n ]+/g, " ").trim();
}

function safeLink(value: string, base: URL): string | undefined {
  try {
    const url = new URL(decodeEntities(value), base);
    if (url.protocol !== "https:" || url.username || url.password || url.port) return undefined;
    url.hash = "";
    return url.toString();
  } catch { return undefined; }
}

export function extractReaderDocument(html: string, base: URL): Omit<ReaderPage, "url"> {
  const titleMatch = /<title\b[^>]*>([\s\S]*?)<\/title>/i.exec(html);
  const links: ReaderLink[] = [];
  const seen = new Set<string>();
  const anchorPattern = /<a\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>([\s\S]*?)<\/a>/gi;
  for (const match of html.matchAll(anchorPattern)) {
    const url = safeLink(match[1] ?? match[2] ?? match[3] ?? "", base);
    const label = plainText(match[4] ?? "").slice(0, 140);
    if (!url || !label || seen.has(url)) continue;
    seen.add(url);
    links.push({ label, url });
    if (links.length >= MAX_LINKS) break;
  }
  const cleaned = html
    .replace(/<(script|style|noscript|svg|iframe|form|nav|footer)\b[^>]*>[\s\S]*?<\/\1>/gi, " ")
    .replace(/<(br|hr|\/p|\/div|\/li|\/h[1-6]|\/article|\/section|\/blockquote)>/gi, "\n")
    .replace(/<[^>]+>/g, " ");
  const body = decodeEntities(cleaned).replace(/[\t\r ]+/g, " ").replace(/ *\n */g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  const title = plainText(titleMatch?.[1] ?? "Web reader").slice(0, 160) || "Web reader";
  return { title, body: body.slice(0, 40_000), links };
}

export async function fetchReaderPage(value: string, dependencies: Partial<ReaderDependencies> = {}): Promise<ReaderPage> {
  const current = { lookup, get: networkGet, ...dependencies };
  let destination = await assertPublicHttps(normalizeReaderInput(value), current.lookup);
  for (let redirect = 0; redirect <= MAX_REDIRECTS; redirect++) {
    const response = await current.get(destination);
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.location;
      if (!location || redirect === MAX_REDIRECTS) throw new Error("reader redirect limit exceeded");
      destination = await assertPublicHttps(new URL(location, destination.url).toString(), current.lookup);
      continue;
    }
    if (response.status < 200 || response.status >= 300) throw new Error(`reader upstream returned HTTP ${response.status}`);
    const contentType = response.headers["content-type"]?.split(";", 1)[0]?.trim().toLowerCase();
    if (contentType !== "text/html" && contentType !== "text/plain") throw new Error("reader supports HTML and plain text only");
    const declared = Number(response.headers["content-length"] ?? 0);
    if (declared > MAX_BYTES) throw new Error("reader response is too large");
    const text = response.bytes.toString("utf8");
    const page = contentType === "text/plain"
      ? { title: destination.url.hostname, body: text.slice(0, 40_000), links: [] }
      : extractReaderDocument(text, destination.url);
    return { url: destination.url.toString(), ...page };
  }
  throw new Error("reader failed");
}
