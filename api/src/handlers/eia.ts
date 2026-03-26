import { err, json, requireApiKey } from "../auth.ts";
import {
	areEIAAveragesFresh,
	getEIAAverages,
	upsertEIAAverages,
	type EIAAverage,
} from "../db.ts";
import { fetchStateAverages } from "../eia.ts";

export async function handleEIAAverages(req: Request): Promise<Response> {
	const authErr = requireApiKey(req);
	if (authErr) return authErr;

	if (!areEIAAveragesFresh()) {
		try {
			const averages = await fetchStateAverages();
			const now = Date.now();
			upsertEIAAverages(
				averages.map((a) => ({ ...a, fetchedAt: now })),
			);
		} catch (e) {
			console.error("EIA fetch failed:", e);
			// Fall through — return stale cache if available
		}
	}

	const averages = getEIAAverages();
	if (averages.length === 0) {
		return err("EIA data not yet available", 503);
	}

	return json(averages);
}

// Refresh EIA averages in the background (call on startup + weekly)
export async function refreshEIAAverages(): Promise<void> {
	if (areEIAAveragesFresh()) return;
	try {
		const averages = await fetchStateAverages();
		const now = Date.now();
		upsertEIAAverages(averages.map((a) => ({ ...a, fetchedAt: now })));
		console.log(`EIA averages refreshed for ${averages.length} states`);
	} catch (e) {
		console.error("EIA background refresh failed:", e);
	}
}
