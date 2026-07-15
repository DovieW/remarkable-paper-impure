import { loadConfig } from "./config.js";
import { buildServer } from "./server.js";

const config = loadConfig();
const { app, adminApp, providers } = buildServer(config);

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => void Promise.all([adminApp.close(), app.close()]).finally(() => process.exit(0)));
}

await adminApp.listen({ host: config.adminHost, port: config.adminPort });
await app.listen({ host: config.host, port: config.port });
providers.start();
