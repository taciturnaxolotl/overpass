type Handler = (req: Request) => Promise<Response> | Response;

export function logged(handler: Handler): Handler {
	return async (req: Request) => {
		const start = Date.now();
		const url = new URL(req.url);
		const res = await handler(req);
		console.log(`${req.method} ${url.pathname} → ${res.status} (${Date.now() - start}ms)`);
		return res;
	};
}
