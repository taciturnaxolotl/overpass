import { err, json, requireDeviceSecret } from "../auth.ts";
import { createApiKey } from "../db.ts";

export async function handleRegisterKey(req: Request): Promise<Response> {
	console.log("POST /keys/register — Authorization:", req.headers.get("Authorization")?.slice(0, 12) ?? "(none)");
	const authErr = requireDeviceSecret(req);
	if (authErr) return authErr;

	let email: string | null = null;
	try {
		const body = (await req.json()) as { email?: string };
		email = typeof body.email === "string" ? body.email : null;
	} catch {
		return err("Invalid JSON body", 400);
	}

	const key = createApiKey(email);
	return json({ key }, 201);
}
