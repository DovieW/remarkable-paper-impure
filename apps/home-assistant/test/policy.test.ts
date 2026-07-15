import assert from "node:assert/strict";
import test from "node:test";
import { classify } from "../src/policy.js";

test("classifies conservative Home Assistant actions", () => {
  assert.equal(classify("light", "toggle"), "low");
  assert.equal(classify("cover", "open_cover"), "confirm");
  assert.equal(classify("lock", "unlock"), "denied");
});
