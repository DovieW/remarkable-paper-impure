import { hashToken, tokenMatches } from "@paperboard/core";
import type { FastifyRequest } from "fastify";
import type { Store } from "./store.js";

export function bearer(request: FastifyRequest): string | undefined {
  const value = request.headers.authorization;
  if (!value?.startsWith("Bearer ")) return undefined;
  const token = value.slice(7).trim();
  return token.length > 0 ? token : undefined;
}

export function requireDevice(request: FastifyRequest, store: Store, deviceId: string): boolean {
  const token = bearer(request);
  const device = store.getDevice(deviceId);
  return Boolean(token && device && tokenMatches(token, device.token_hash));
}

export function requireScope(request: FastifyRequest, store: Store, scope: string): boolean {
  const token = bearer(request);
  if (!token) return false;
  const client = store.getClientByHash(hashToken(token));
  return Boolean(client?.scopes.split(" ").includes(scope));
}

export function requireAdmin(request: FastifyRequest, adminToken: string): boolean {
  const token = bearer(request);
  return Boolean(token && tokenMatches(token, hashToken(adminToken)));
}
