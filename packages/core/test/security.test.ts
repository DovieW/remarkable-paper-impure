import assert from "node:assert/strict";
import test from "node:test";
import { decryptSecret, encryptSecret, issueToken, parseMasterKey, tokenMatches } from "../src/index.js";

test("issues and verifies high-entropy tokens", () => {
  const issued = issueToken("pb_client");
  assert.match(issued.token, /^pb_client_[A-Za-z0-9_-]{40,}$/);
  assert.equal(tokenMatches(issued.token, issued.hash), true);
  assert.equal(tokenMatches(`${issued.token}x`, issued.hash), false);
});

test("encrypts upstream credentials with authenticated encryption", () => {
  const key = parseMasterKey(Buffer.alloc(32, 7).toString("base64"));
  const encrypted = encryptSecret("private-value", key);
  assert.notEqual(encrypted, "private-value");
  assert.equal(decryptSecret(encrypted, key), "private-value");
  assert.throws(() => decryptSecret(`${encrypted.slice(0, -1)}A`, key));
});
