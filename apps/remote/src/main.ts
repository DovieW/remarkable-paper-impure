import { SshTabletController } from "./controller.js";
import { buildRemoteServer } from "./server.js";

const host = process.env.REMARKABLE_HOST ?? "remarkable-usb";
const port = Number.parseInt(process.env.PAPER_REMOTE_PORT ?? "4174", 10);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("PAPER_REMOTE_PORT must be between 1 and 65535");

const controller = new SshTabletController(host);
const { server } = buildRemoteServer(controller);
server.listen(port, "127.0.0.1", () => {
  console.log(`Paper Pure Remote: http://127.0.0.1:${port}`);
  console.log(`SSH target: ${host}`);
  console.log("Input is disarmed until you confirm the tablet is physically unlocked.");
});

function shutdown(): void {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5000).unref();
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
