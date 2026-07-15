import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { PaperboardClient } from "@paperboard/client";
import { createPaperboardMcpServer } from "./server.js";

const url = process.env.PAPERBOARD_URL ?? "http://127.0.0.1:8787";
const token = process.env.PAPERBOARD_TOKEN;
if (!token) throw new Error("PAPERBOARD_TOKEN is required");
const client = new PaperboardClient({ baseUrl: url, token });
const server = createPaperboardMcpServer(client);
await server.connect(new StdioServerTransport());
