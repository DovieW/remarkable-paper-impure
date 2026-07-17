export type OperationNamespace = "dashboard" | "screen" | "device" | "admin";
export type OperationMethod = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";

export interface OperationDefinition {
  id: string;
  namespace: OperationNamespace;
  method: OperationMethod;
  path: string;
  scope: string;
  cli: string;
  mcp: string;
  description: string;
}

/*
 * The registry is the public v2 contract. HTTP clients, the CLI, MCP and
 * contract tests consume these identifiers instead of independently naming
 * the same operation four times.
 */
export const operationRegistry = [
  { id: "dashboard.asset.upload", namespace: "dashboard", method: "POST", path: "/v2/devices/:device/dashboard/assets", scope: "dashboard:write", cli: "dashboard asset upload", mcp: "dashboard_asset_upload", description: "Upload a dashboard or screen image asset." },
  { id: "dashboard.card.create", namespace: "dashboard", method: "POST", path: "/v2/devices/:device/dashboard/cards", scope: "dashboard:write", cli: "dashboard show", mcp: "dashboard_show", description: "Queue a dashboard card without foregrounding Paperboard." },
  { id: "dashboard.card.update", namespace: "dashboard", method: "PATCH", path: "/v2/devices/:device/dashboard/cards/:card", scope: "dashboard:write", cli: "dashboard update", mcp: "dashboard_update", description: "Update a dashboard card." },
  { id: "dashboard.card.list", namespace: "dashboard", method: "GET", path: "/v2/devices/:device/dashboard/cards", scope: "dashboard:read", cli: "dashboard list", mcp: "dashboard_list", description: "List dashboard cards." },
  { id: "dashboard.card.get", namespace: "dashboard", method: "GET", path: "/v2/devices/:device/dashboard/cards/:card", scope: "dashboard:read", cli: "dashboard get", mcp: "dashboard_get", description: "Read a dashboard card." },
  { id: "dashboard.card.delete", namespace: "dashboard", method: "DELETE", path: "/v2/devices/:device/dashboard/cards/:card", scope: "dashboard:clear", cli: "dashboard delete", mcp: "dashboard_delete", description: "Delete a dashboard card." },
  { id: "dashboard.clear", namespace: "dashboard", method: "POST", path: "/v2/devices/:device/dashboard/clear", scope: "dashboard:clear", cli: "dashboard clear", mcp: "dashboard_clear", description: "Clear dashboard cards." },
  { id: "screen.session.create", namespace: "screen", method: "POST", path: "/v2/devices/:device/screen/sessions", scope: "screen:write", cli: "screen start", mcp: "screen_start", description: "Create an interactive screen session." },
  { id: "screen.session.list", namespace: "screen", method: "GET", path: "/v2/devices/:device/screen/sessions", scope: "screen:read", cli: "screen list", mcp: "screen_list", description: "List screen sessions." },
  { id: "screen.session.get", namespace: "screen", method: "GET", path: "/v2/devices/:device/screen/sessions/:session", scope: "screen:read", cli: "screen status", mcp: "screen_status", description: "Read a screen session and history." },
  { id: "screen.message.present", namespace: "screen", method: "POST", path: "/v2/devices/:device/screen/sessions/:session/messages", scope: "screen:write", cli: "screen present", mcp: "screen_present", description: "Present screen content and request Screen foreground." },
  { id: "screen.event.list", namespace: "screen", method: "GET", path: "/v2/devices/:device/screen/sessions/:session/events", scope: "screen:read", cli: "screen events", mcp: "screen_events", description: "Read screen interaction events." },
  { id: "screen.event.ack", namespace: "screen", method: "POST", path: "/v2/devices/:device/screen/sessions/:session/events/:event/ack", scope: "screen:write", cli: "screen ack", mcp: "screen_ack", description: "Acknowledge a screen event." },
  { id: "screen.session.close", namespace: "screen", method: "POST", path: "/v2/devices/:device/screen/sessions/:session/close", scope: "screen:write", cli: "screen close", mcp: "screen_close", description: "Close a screen session." },
  { id: "device.status", namespace: "device", method: "GET", path: "/v2/devices/:device/status", scope: "status:read", cli: "device status", mcp: "device_status", description: "Read relay, tablet and visible UI state." },
  { id: "device.apps", namespace: "device", method: "GET", path: "/v2/devices/:device/apps", scope: "device:apps", cli: "device apps", mcp: "device_apps", description: "List safe launchable tablet applications." },
  { id: "device.launch", namespace: "device", method: "POST", path: "/v2/devices/:device/apps/launch", scope: "device:control", cli: "device launch", mcp: "device_launch", description: "Launch an allowlisted tablet application." },
  { id: "device.exit", namespace: "device", method: "POST", path: "/v2/devices/:device/exit", scope: "device:control", cli: "device exit", mcp: "device_exit", description: "Exit the current custom tablet application." },
  { id: "device.screenshot", namespace: "device", method: "GET", path: "/v2/devices/:device/screenshot", scope: "screen:read", cli: "device screenshot", mcp: "device_screenshot", description: "Capture the unlocked tablet display." },
  { id: "device.command", namespace: "device", method: "POST", path: "/v2/devices/:device/commands", scope: "device:control", cli: "device control", mcp: "device_control", description: "Queue a bounded semantic tablet command." },
  { id: "device.command.status", namespace: "device", method: "GET", path: "/v2/devices/:device/commands/:command", scope: "device:control", cli: "device command-status", mcp: "device_command_status", description: "Read the outcome of a bounded semantic tablet command." },
] as const satisfies readonly OperationDefinition[];

export type OperationId = typeof operationRegistry[number]["id"];

export function operation(id: OperationId): OperationDefinition {
  const found = operationRegistry.find((candidate) => candidate.id === id);
  if (!found) throw new Error(`unknown Paperboard operation: ${id}`);
  return found;
}

export function operationPath(id: OperationId, values: Record<string, string>): string {
  return operation(id).path.replace(/:([a-z_]+)/g, (_match, key: string) => {
    const value = values[key];
    if (!value) throw new Error(`missing path parameter ${key} for ${id}`);
    return encodeURIComponent(value);
  });
}
