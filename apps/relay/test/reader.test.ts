import assert from "node:assert/strict";
import type { LookupAddress } from "node:dns";
import test from "node:test";
import { extractReaderDocument, fetchReaderPage, normalizeReaderInput } from "../src/reader.js";

const publicLookup = async () => [{ address: "93.184.216.34", family: 4 as const }];

test("normalizes addresses and searches without accepting insecure schemes", () => {
  assert.equal(normalizeReaderInput("https://example.com/story"), "https://example.com/story");
  assert.equal(normalizeReaderInput("example.com/story"), "https://example.com/story");
  assert.equal(normalizeReaderInput("paper tablet"), "https://lite.duckduckgo.com/lite/?q=paper%20tablet");
  assert.equal(normalizeReaderInput("http://example.com"), "https://lite.duckduckgo.com/lite/?q=http%3A%2F%2Fexample.com");
});

test("extracts readable text and safe, deduplicated HTTPS links", () => {
  const result = extractReaderDocument(`
    <html><head><title>Quiet &amp; useful</title><style>hidden</style></head>
    <body><nav>menu</nav><h1>Paper web</h1><p>Readable copy.</p>
    <a href="/next">Next chapter</a><a href="/next">Duplicate</a>
    <a href="http://example.com/no">Insecure</a><a href="https://user@example.com/no">Credentials</a>
    <script>alert('no')</script></body></html>`, new URL("https://example.com/start"));
  assert.equal(result.title, "Quiet & useful");
  assert.match(result.body, /Paper web/);
  assert.doesNotMatch(result.body, /alert|menu/);
  assert.deepEqual(result.links, [{ label: "Next chapter", url: "https://example.com/next" }]);
});

test("fetches a public page through pinned DNS and revalidates redirects", async () => {
  const page = await fetchReaderPage("example.com", {
    lookup: publicLookup as never,
    get: async (destination) => ({
      status: 200,
      headers: { "content-type": "text/html" },
      bytes: Buffer.from(`<title>Example</title><p>Hello</p><a href="/more">More</a>`),
    }),
  });
  assert.equal(page.url, "https://example.com/");
  assert.equal(page.title, "Example");
  assert.deepEqual(page.links, [{ label: "More", url: "https://example.com/more" }]);

  await assert.rejects(() => fetchReaderPage("https://example.com", {
    lookup: (async (hostname: string) => hostname === "internal.example"
      ? [{ address: "192.168.1.5", family: 4 }]
      : [{ address: "93.184.216.34", family: 4 }]) as never,
    get: async () => ({ status: 302, headers: { location: "https://internal.example/private" }, bytes: Buffer.alloc(0) }),
  }), /not public/);
});

test("rejects private destinations before making a request", async () => {
  let requested = false;
  await assert.rejects(() => fetchReaderPage("https://localhost", {
    lookup: (async () => [{ address: "127.0.0.1", family: 4 } satisfies LookupAddress]) as never,
    get: async () => { requested = true; return { status: 200, headers: { "content-type": "text/plain" }, bytes: Buffer.from("bad") }; },
  }), /not public/);
  assert.equal(requested, false);
});
