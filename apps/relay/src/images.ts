import { createHash } from "node:crypto";
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import sharp from "sharp";

export const MAX_INPUT_BYTES = 12 * 1024 * 1024;
const MAX_PIXELS = 40_000_000;

function privateIpv4(address: string): boolean {
  const octets = address.split(".").map(Number);
  const [a, b] = octets;
  return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) ||
    (a === 172 && b !== undefined && b >= 16 && b <= 31) || (a === 192 && b === 168) ||
    (a === 100 && b !== undefined && b >= 64 && b <= 127);
}

function privateIpv6(address: string): boolean {
  const normalized = address.toLowerCase();
  return normalized === "::" || normalized === "::1" || normalized.startsWith("fe80:") ||
    normalized.startsWith("fc") || normalized.startsWith("fd");
}

export function isPrivateAddress(address: string): boolean {
  const family = isIP(address);
  return family === 4 ? privateIpv4(address) : family === 6 ? privateIpv6(address) : true;
}

export async function validateUpstreamUrl(raw: string, allowPrivateHttp = false): Promise<URL> {
  const url = new URL(raw);
  if (url.username || url.password) throw new Error("upstream URL must not contain user info");
  if (url.protocol !== "https:" && !(allowPrivateHttp && url.protocol === "http:")) {
    throw new Error("upstream URL must use HTTPS");
  }
  if (allowPrivateHttp) return url;
  const records = await lookup(url.hostname, { all: true, verbatim: true });
  if (records.length === 0 || records.some((record) => isPrivateAddress(record.address))) {
    throw new Error("upstream URL resolves to a private, loopback, or link-local address");
  }
  return url;
}

export async function readLimited(response: Response): Promise<Buffer> {
  if (!response.ok) throw new Error(`upstream returned HTTP ${response.status}`);
  const type = response.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
  if (!type || !["image/png", "image/jpeg", "image/bmp", "application/octet-stream"].includes(type)) {
    throw new Error(`unsupported upstream content type: ${type ?? "missing"}`);
  }
  const length = Number(response.headers.get("content-length") ?? 0);
  if (length > MAX_INPUT_BYTES) throw new Error("upstream image exceeds 12 MiB");
  if (!response.body) throw new Error("upstream response has no body");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    received += value.byteLength;
    if (received > MAX_INPUT_BYTES) {
      await reader.cancel();
      throw new Error("upstream image exceeds 12 MiB");
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks, received);
}

export async function normalizeImage(input: Buffer): Promise<{ png: Buffer; sha256: string }> {
  if (input.length === 0 || input.length > MAX_INPUT_BYTES) throw new Error("image must be between 1 byte and 12 MiB");
  const decoder = sharp(input, { failOn: "warning", limitInputPixels: MAX_PIXELS, sequentialRead: true });
  const metadata = await decoder.metadata();
  if (!metadata.width || !metadata.height || !["png", "jpeg", "bmp"].includes(metadata.format ?? "")) {
    throw new Error("only decodable PNG, JPEG, and BMP images are accepted");
  }
  const png = await decoder
    .rotate()
    .flatten({ background: "#f1efe6" })
    .resize(1404, 1872, { fit: "contain", background: "#f1efe6", withoutEnlargement: false })
    .grayscale()
    .png({ compressionLevel: 9, colours: 256, dither: 0.8 })
    .toBuffer();
  return { png, sha256: createHash("sha256").update(png).digest("hex") };
}

export async function fetchImage(url: string, token?: string, allowPrivateHttp = false): Promise<Buffer> {
  const validated = await validateUpstreamUrl(url, allowPrivateHttp);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);
  try {
    const response = await fetch(validated, {
      redirect: "error",
      signal: controller.signal,
      headers: { accept: "image/png,image/jpeg,image/bmp", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    });
    return await readLimited(response);
  } finally {
    clearTimeout(timeout);
  }
}
