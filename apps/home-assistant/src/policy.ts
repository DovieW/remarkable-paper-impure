export type Risk = "low" | "confirm" | "denied";

const lowRiskDomains = new Set(["light", "switch", "input_boolean", "media_player", "fan"]);
const confirmDomains = new Set(["cover", "climate", "scene", "vacuum"]);

export function classify(domain: string, service: string): Risk {
  if (["lock", "alarm_control_panel", "camera", "script", "automation", "button"].includes(domain)) return "denied";
  if (confirmDomains.has(domain)) return "confirm";
  if (lowRiskDomains.has(domain) && ["turn_on", "turn_off", "toggle", "pause", "play_media", "set_percentage"].includes(service)) return "low";
  return "denied";
}
