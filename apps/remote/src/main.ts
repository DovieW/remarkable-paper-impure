import { SshTabletController } from "./controller.js";
import { buildRemoteServer } from "./server.js";

const host = process.env.REMARKABLE_HOST ?? "remarkable-usb";
const port = Number.parseInt(process.env.PAPER_REMOTE_PORT ?? "4174", 10);
const bind = process.env.PAPER_REMOTE_BIND ?? "127.0.0.1";
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("PAPER_REMOTE_PORT must be between 1 and 65535");

const controller = new SshTabletController(host);
const { server } = buildRemoteServer(controller, {
  inputEnabled: process.env.PAPER_REMOTE_INPUT_ENABLED === "true",
  killSwitchPath: process.env.PAPER_REMOTE_KILL_SWITCH ?? "/run/paperboard-remote.disabled",
  basePath: process.env.PAPER_REMOTE_BASE_PATH ?? "",
});
server.listen(port, bind, () => {
  console.log(`Paper Pure Remote listening on ${bind}:${port}`);
  console.log(`SSH target: ${host}`);
  console.log("Input requires PAPER_REMOTE_INPUT_ENABLED=true and an absent kill-switch file.");
});

function shutdown(): void {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5000).unref();
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
