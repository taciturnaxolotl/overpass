import { err, json, requireApiKey, requireApiKeyNoRateLimit } from "../auth.ts";
import {
	isCellFresh,
	markCellFetched,
	queryStationsInBbox,
	queryStationsNear,
	upsertStations,
} from "../db.ts";
import { fetchStationsByLocation } from "../gasbuddy.ts";
import { latLngToCell } from "../geo.ts";

const NEARBY_TTL_MS = 30 * 60 * 1000; // 30 minutes
const MAX_BBOX_AREA = 0.5;

export async function handleNearby(req: Request): Promise<Response> {
	const url = new URL(req.url);
	const cacheOnly = url.searchParams.get("cache_only") === "true";
	const authErr = cacheOnly ? requireApiKeyNoRateLimit(req) : requireApiKey(req);
	if (authErr) return authErr;

	const lat = parseFloat(url.searchParams.get("lat") ?? "");
	const lng = parseFloat(url.searchParams.get("lng") ?? "");
	const radiusKm = parseFloat(url.searchParams.get("radius_km") ?? "8");

	if (!isFinite(lat) || !isFinite(lng)) {
		return err("lat and lng are required", 400);
	}
	if (!isFinite(radiusKm) || radiusKm <= 0) {
		return err("radius_km must be a positive number", 400);
	}

	// Validate bbox area
	const latDelta = radiusKm / 111;
	const lngDelta =
		radiusKm / (111 * Math.cos((lat * Math.PI) / 180));
	if (latDelta * 2 * lngDelta * 2 > MAX_BBOX_AREA) {
		return err(
			"Requested area exceeds 0.5 deg² limit. Reduce radius_km.",
			400,
		);
	}
	const cellKey = latLngToCell(lat, lng);

	// Serve from cache if fresh or cache_only requested
	if (!cacheOnly && !isCellFresh(cellKey, NEARBY_TTL_MS)) {
		try {
			const stations = await fetchStationsByLocation(lat, lng);
			upsertStations(stations);
			markCellFetched(cellKey);
		} catch (e) {
			console.error("GasBuddy fetch failed:", e);
			// Fall through to stale cache rather than error
		}
	}

	const stations = queryStationsNear(lat, lng, radiusKm);
	return json(stations);
}

export async function handleBbox(req: Request): Promise<Response> {
	const authErr = requireApiKeyNoRateLimit(req);
	if (authErr) return authErr;

	const url = new URL(req.url);
	const minLat = parseFloat(url.searchParams.get("min_lat") ?? "");
	const minLng = parseFloat(url.searchParams.get("min_lng") ?? "");
	const maxLat = parseFloat(url.searchParams.get("max_lat") ?? "");
	const maxLng = parseFloat(url.searchParams.get("max_lng") ?? "");

	if (
		!isFinite(minLat) ||
		!isFinite(minLng) ||
		!isFinite(maxLat) ||
		!isFinite(maxLng)
	) {
		return err("min_lat, min_lng, max_lat, max_lng are required", 400);
	}

	const area = (maxLat - minLat) * (maxLng - minLng);
	if (area <= 0 || area > MAX_BBOX_AREA) {
		return err(
			"Bbox area must be positive and ≤ 0.5 deg²",
			400,
		);
	}

	const stations = queryStationsInBbox(minLat, minLng, maxLat, maxLng);
	return json(stations);
}
