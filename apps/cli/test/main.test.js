import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { operationRegistry } from "../../../packages/core/dist/operations.js";

const cliPath = fileURLToPath(new URL("../dist/main.js", import.meta.url));

function runCli(arguments_, environment) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [cliPath, ...arguments_], {
      env: { ...process.env, ...environment },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

test("admin provider set reaches the loopback admin API", async (context) => {
  let observed;
  const server = createServer((request, response) => {
    let body = "";
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      observed = {
        method: request.method,
        url: request.url,
        authorization: request.headers.authorization,
        body: JSON.parse(body),
      };
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify({ kind: "none" }));
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  context.after(() => server.close());
  const address = server.address();
  assert.ok(address && typeof address !== "string");

  const result = await runCli([
    "admin", "provider", "set", "--device", "paper-pure", "--kind", "none",
  ], {
    PAPERBOARD_ADMIN_URL: `http://127.0.0.1:${address.port}`,
    PAPERBOARD_ADMIN_TOKEN: "test-admin-token",
  });

  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { kind: "none" });
  assert.deepEqual(observed, {
    method: "PUT",
    url: "/admin/devices/paper-pure/provider",
    authorization: "Bearer test-admin-token",
    body: { kind: "none" },
  });
});

test("CLI recognizes every public v2 operation", async () => {
  for (const operation of operationRegistry) {
    const result = await runCli([...operation.cli.split(" "), "--unexpected"], {});
    assert.doesNotMatch(result.stderr, /^Usage:/m, `${operation.cli} is missing from the CLI dispatcher`);
    assert.notEqual(result.code, 2, `${operation.cli} fell through to CLI usage`);
  }
});
