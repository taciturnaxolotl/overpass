import { serve } from "bun";
import { getDb } from "./db.ts";
import { handleEIAAverages, refreshEIAAverages } from "./handlers/eia.ts";
import { handleHealth } from "./handlers/health.ts";
import { handleRegisterKey } from "./handlers/keys.ts";
import { logged } from "./logger.ts";
import { handleBbox, handleNearby } from "./handlers/stations.ts";
import { handlePrefetchRoute } from "./handlers/prefetch.ts";

// Initialize DB on startup
getDb();

// Kick off EIA refresh in background (won't block startup)
refreshEIAAverages();

const server = serve({
	port: process.env.PORT ? parseInt(process.env.PORT, 10) : 7878,

	routes: {
		"/health": { GET: logged(handleHealth) },
		"/keys/register": { POST: logged(handleRegisterKey) },
		"/stations/nearby": { GET: logged(handleNearby) },
		"/stations/bbox": { GET: logged(handleBbox) },
		"/prefetch/route": { POST: logged(handlePrefetchRoute) },
		"/eia/averages": { GET: logged(handleEIAAverages) },
	},

	fetch(req) {
		const url = new URL(req.url);
		console.log(`${req.method} ${url.pathname} → 404`);
		return new Response("Not found", { status: 404 });
	},
});

console.log(`gastrack listening on ${server.hostname}:${server.port}`);

process.on("SIGINT", () => process.exit(0));
process.on("SIGTERM", () => process.exit(0));

process.on("unhandledRejection", (reason) => {
	console.error("Unhandled rejection:", reason);
});
