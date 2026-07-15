import assert from "node:assert/strict";
import test from "node:test";
import { isPrivateAddress, validateUpstreamUrl } from "../src/images.js";

test("classifies private and special network destinations", () => {
  for (const address of ["127.0.0.1", "10.1.2.3", "172.20.1.1", "192.168.1.1", "169.254.1.2", "::1", "fd00::1", "fe80::1"]) assert.equal(isPrivateAddress(address), true, address);
  assert.equal(isPrivateAddress("1.1.1.1"), false);
  assert.equal(isPrivateAddress("2606:4700:4700::1111"), false);
});

test("requires HTTPS and rejects URL credentials", async () => {
  await assert.rejects(validateUpstreamUrl("http://example.com/image.png"), /HTTPS/);
  await assert.rejects(validateUpstreamUrl("https://user:pass@example.com/image.png"), /user info/);
  const internal = await validateUpstreamUrl("http://terminus:3000/image.png", true);
  assert.equal(internal.hostname, "terminus");
});
