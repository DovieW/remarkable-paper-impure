import assert from "node:assert/strict";
import test from "node:test";
import { operationPath, operationRegistry } from "../src/operations.js";

test("v2 operation identifiers are unique and namespaced", () => {
  for (const field of ["id", "cli", "mcp"] as const) {
    const values = operationRegistry.map((item) => item[field]);
    assert.equal(new Set(values).size, values.length, `duplicate ${field}`);
  }
  const routes = operationRegistry.map((item) => `${item.method} ${item.path}`);
  assert.equal(new Set(routes).size, routes.length, "duplicate method/path route");
  for (const item of operationRegistry) {
    assert.ok(item.path.startsWith("/v2/"));
    assert.ok(item.id.startsWith(`${item.namespace}.`));
    assert.ok(item.cli.startsWith(`${item.namespace} `));
    assert.ok(item.mcp.startsWith(`${item.namespace}_`));
  }
});

test("operation paths encode caller-controlled identifiers", () => {
  assert.equal(
    operationPath("screen.event.ack", { device: "pure one", session: "session/one", event: "event?one" }),
    "/v2/devices/pure%20one/screen/sessions/session%2Fone/events/event%3Fone/ack",
  );
});
