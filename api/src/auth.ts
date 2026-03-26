import { checkRateLimit, lookupApiKey } from "./db.ts";

export function json(data: unknown, status = 200): Response {
	return Response.json(data, { status });
}

export function err(message: string, status: number): Response {
	return json({ error: message }, status);
}

export function bearerToken(request: Request): string | null {
	const header = request.headers.get("Authorization");
	if (!header?.startsWith("Bearer ")) return null;
	return header.slice(7).trim();
}

export function requireDeviceSecret(request: Request): Response | null {
	const token = bearerToken(request);
	const secret = process.env.GASTRACK_DEVICE_SECRET;
	if (!secret) {
		console.error("GASTRACK_DEVICE_SECRET not set");
		return err("Server misconfigured", 500);
	}
	if (token !== secret) {
		console.error(
			`Auth mismatch — got: "${token?.slice(0, 6)}…" expected: "${secret.slice(0, 6)}…"`,
		);
		return err("Unauthorized", 401);
	}
	return null;
}

export function requireApiKey(request: Request): Response | null {
	const token = bearerToken(request);
	if (!token) return err("Missing Authorization header", 401);
	if (!lookupApiKey(token)) return err("Invalid API key", 401);
	if (!checkRateLimit(token)) return err("Rate limit exceeded", 429);
	return null;
}

// Auth-only, no rate limit. Use for cache-only endpoints that never call upstream APIs.
export function requireApiKeyNoRateLimit(request: Request): Response | null {
	const token = bearerToken(request);
	if (!token) return err("Missing Authorization header", 401);
	if (!lookupApiKey(token)) return err("Invalid API key", 401);
	return null;
}
