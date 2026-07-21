import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import test from "node:test";
import { PaperboardAdminClient, PaperboardClient } from "../src/index.js";

interface ObservedRequest {
  method?: string;
  url?: string;
  authorization?: string;
  contentType?: string;
  idempotencyKey?: string;
  body: Buffer;
}

async function withServer(
  context: test.TestContext,
  handler: (request: IncomingMessage, response: ServerResponse) => void,
): Promise<{ baseUrl: string; observed: ObservedRequest[] }> {
  const observed: ObservedRequest[] = [];
  const server = createServer((request, response) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk: Buffer) => chunks.push(chunk));
    request.on("end", () => {
      observed.push({
        method: request.method,
        url: request.url,
        authorization: request.headers.authorization,
        contentType: request.headers["content-type"],
        idempotencyKey: request.headers["idempotency-key"],
        body: Buffer.concat(chunks),
      });
      handler(request, response);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  context.after(() => server.close());
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  return { baseUrl: `http://127.0.0.1:${address.port}/`, observed };
}

test("client sends authenticated JSON with encoded paths and idempotency", async (context) => {
  const fixture = await withServer(context, (_request, response) => {
    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify({ id: "card-1", cursor: 4 }));
  });
  const client = new PaperboardClient({ baseUrl: fixture.baseUrl, token: "client-token" });

  const result = await client.show("pure one", { kind: "text", title: "Hello", body: "World" }, "request-1");

  assert.deepEqual(result, { id: "card-1", cursor: 4 });
  assert.deepEqual(fixture.observed[0], {
    method: "POST",
    url: "/v2/devices/pure%20one/dashboard/cards",
    authorization: "Bearer client-token",
    contentType: "application/json",
    idempotencyKey: "request-1",
    body: Buffer.from(JSON.stringify({ kind: "text", title: "Hello", body: "World" })),
  });
});

test("client handles binary and empty responses", async (context) => {
  const png = Buffer.from("89504e470d0a1a0a", "hex");
  const fixture = await withServer(context, (request, response) => {
    if (request.method === "DELETE") {
      response.statusCode = 204;
      response.end();
      return;
    }
    response.setHeader("content-type", "image/png");
    response.end(png);
  });
  const client = new PaperboardClient({ baseUrl: fixture.baseUrl, token: "client-token" });

  assert.deepEqual(await client.deviceScreenshot("pure"), png);
  await client.delete("pure", "card/with spaces");
  assert.equal(fixture.observed[1]?.url, "/v2/devices/pure/dashboard/cards/card%2Fwith%20spaces");
  assert.equal(fixture.observed[1]?.method, "DELETE");
});

test("client errors retain status but bound untrusted response text", async (context) => {
  const fixture = await withServer(context, (_request, response) => {
    response.statusCode = 503;
    response.end("x".repeat(800));
  });
  const client = new PaperboardClient({ baseUrl: fixture.baseUrl, token: "client-token" });

  await assert.rejects(client.list("pure"), (error: Error) => {
    assert.match(error.message, /^Paperboard HTTP 503: /);
    assert.equal(error.message.length, "Paperboard HTTP 503: ".length + 500);
    return true;
  });
});

test("admin client authenticates and encodes caller-controlled identifiers", async (context) => {
  const fixture = await withServer(context, (_request, response) => {
    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify({ revoked: true }));
  });
  const client = new PaperboardAdminClient({ baseUrl: fixture.baseUrl, token: "admin-token" });

  assert.deepEqual(await client.revokeClient("agent/one"), { revoked: true });
  assert.equal(fixture.observed[0]?.url, "/admin/clients/agent%2Fone");
  assert.equal(fixture.observed[0]?.method, "DELETE");
  assert.equal(fixture.observed[0]?.authorization, "Bearer admin-token");
});
