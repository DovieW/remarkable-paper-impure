import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { __testing } from "../dist/index.js";

test("inventory bounds visible sessions and imports only user-facing history", async () => {
  const root = await mkdtemp(join(tmpdir(), "paperchat-inventory-"));
  try {
    const transcript = join(root, "session.jsonl");
    await writeFile(transcript, [
      { id: "one", timestamp: "2026-07-21T20:00:00.000Z", message: { role: "user", content: [{ type: "text", text: "Hello" }] } },
      { id: "two", timestamp: "2026-07-21T20:00:01.000Z", message: { role: "system", content: "private runtime prompt" } },
      { id: "three", timestamp: "2026-07-21T20:00:02.000Z", message: { role: "assistant", content: [{ type: "text", text: "Hi there" }] } },
    ].map((row) => JSON.stringify(row)).join("\n"), { mode: 0o600 });
    const rows = [
      { sessionKey: "agent:main:paperchat:test", entry: { sessionFile: transcript, label: "Tablet chat", updatedAt: 30 } },
      { sessionKey: "agent:main:global:main", entry: { sessionFile: transcript, updatedAt: 20 } },
      { sessionKey: "agent:main:system:jobs", entry: { sessionFile: transcript, updatedAt: 10 } },
    ];
    const api = {
      config: { agents: { list: [{ id: "main" }] } },
      runtime: { agent: { session: { listSessionEntries: () => rows } } },
    };
    const result = await __testing.inventory(api);
    assert.deepEqual(result.agents, [{ id: "main", name: "main" }]);
    assert.equal(result.sessions.length, 1);
    assert.equal(result.sessions[0].title, "Tablet chat");
    assert.deepEqual(result.messages.map((message) => [message.role, message.body]), [
      ["user", "Hello"],
      ["assistant", "Hi there"],
    ]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
