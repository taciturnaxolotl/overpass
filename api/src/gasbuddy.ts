import type { Price, Station } from "./db.ts";

const GRAPHQL_URL = "https://www.gasbuddy.com/graphql";

const GRAPHQL_QUERY = `
query LocationBySearchTerm($brandId: Int, $cursor: String, $fuel: Int, $lat: Float, $lng: Float, $maxAge: Int, $search: String) {
  locationBySearchTerm(lat: $lat, lng: $lng, search: $search, priority: "locality") {
    latitude
    longitude
    stations(brandId: $brandId, cursor: $cursor, fuel: $fuel, lat: $lat, lng: $lng, maxAge: $maxAge, priority: "locality") {
      results {
        id
        name
        latitude
        longitude
        address {
          line1
          locality
          region
          postalCode
        }
        prices {
          cash { nickname postedTime price formattedPrice }
          credit { nickname postedTime price formattedPrice }
          fuelProduct
        }
      }
    }
  }
}
`;

const FUEL_NICKNAMES: Record<string, string> = {
	regular_gas: "Regular",
	midgrade_gas: "Midgrade",
	premium_gas: "Premium",
	diesel: "Diesel",
	e85: "E85",
	e15: "E15",
};

interface GasBuddyCredit {
	nickname: string | null;
	postedTime: string | null;
	price: number;
	formattedPrice: string;
}

interface GasBuddyPriceEntry {
	cash: GasBuddyCredit | null;
	credit: GasBuddyCredit | null;
	discount: number;
	fuelProduct: string;
}

interface GasBuddyStation {
	id: string;
	name: string;
	latitude: number | null;
	longitude: number | null;
	address: {
		line1: string;
		locality: string;
		region: string;
		postalCode: string;
	};
	prices: GasBuddyPriceEntry[];
}

interface GraphQLResponse {
	data: {
		locationBySearchTerm: {
			latitude: number;
			longitude: number;
			stations: { results: GasBuddyStation[] };
		};
	};
	errors?: Array<{ message: string }>;
}

interface FlareSolverrResult {
	status: string;
	solution: {
		status: number;
		response: string;
		cookies: Array<{ name: string; value: string }>;
		userAgent: string;
	};
}

// --- Throttle ---

let lastFetchTime = 0;

async function throttle(): Promise<void> {
	const elapsed = Date.now() - lastFetchTime;
	if (elapsed < 500) await Bun.sleep(500 - elapsed);
	lastFetchTime = Date.now();
}

// --- Cookie cache (Cloudflare cookies are valid ~30 min) ---

let cachedCookies: string | null = null;
let cachedUserAgent: string | null = null;
let cookieExpiry = 0;
const COOKIE_TTL_MS = 25 * 60 * 1000;

async function getCloudfareCookies(solverrUrl: string): Promise<{ cookies: string; userAgent: string }> {
	if (cachedCookies && cachedUserAgent && Date.now() < cookieExpiry) {
		return { cookies: cachedCookies, userAgent: cachedUserAgent };
	}

	console.log("Refreshing GasBuddy cookies via FlareSolverr…");
	const res = await fetch(`${solverrUrl}/v1`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({
			cmd: "request.get",
			url: "https://www.gasbuddy.com/home",
			maxTimeout: 60000,
		}),
	});

	if (!res.ok) throw new Error(`FlareSolverr returned ${res.status}`);

	const json = (await res.json()) as FlareSolverrResult;
	if (json.status !== "ok") throw new Error(`FlareSolverr error: ${json.status}`);

	cachedCookies = json.solution.cookies.map((c) => `${c.name}=${c.value}`).join("; ");
	cachedUserAgent = json.solution.userAgent;
	cookieExpiry = Date.now() + COOKIE_TTL_MS;

	console.log(`Got ${json.solution.cookies.length} cookies, UA: ${cachedUserAgent?.slice(0, 60)}`);
	return { cookies: cachedCookies, userAgent: cachedUserAgent };
}

// --- GraphQL POST ---

async function graphqlPost(
	lat: number,
	lng: number,
	extraHeaders: Record<string, string> = {},
): Promise<GraphQLResponse> {
	const res = await fetch(GRAPHQL_URL, {
		method: "POST",
		headers: {
			"Content-Type": "application/json",
			"User-Agent":
				"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
			Origin: "https://www.gasbuddy.com",
			Referer: "https://www.gasbuddy.com/",
			"apollo-require-preflight": "true",
			...extraHeaders,
		},
		body: JSON.stringify({
			operationName: "LocationBySearchTerm",
			query: GRAPHQL_QUERY,
			variables: { lat, lng, fuel: 1 },
		}),
	});

	if (!res.ok) {
		const text = await res.text();
		throw new Error(`GasBuddy ${res.status}: ${text.slice(0, 200)}`);
	}

	return res.json() as Promise<GraphQLResponse>;
}

// --- Result mapping ---

function mapResults(loc: GraphQLResponse["data"]["locationBySearchTerm"]): Station[] {
	const now = Date.now();
	return loc.stations.results.map((r) => ({
		id: r.id,
		name: r.name,
		lat: r.latitude ?? loc.latitude,
		lng: r.longitude ?? loc.longitude,
		address: r.address.line1 || null,
		city: r.address.locality || null,
		state: r.address.region || null,
		zip: r.address.postalCode.trim() || null,
		prices: mapPrices(r.prices),
		fetchedAt: now,
	}));
}

function mapPrices(entries: GasBuddyPriceEntry[]): Price[] {
	return entries.map((entry) => {
		const nickname = FUEL_NICKNAMES[entry.fuelProduct] ?? entry.fuelProduct;
		const p = entry.credit ?? entry.cash;
		const formattedPrice =
			p && p.formattedPrice !== "- - -" && p.price > 0 ? p.formattedPrice : null;
		return { nickname, formattedPrice, postedTime: p?.postedTime ?? null };
	});
}

// --- Public API ---

export async function fetchStationsByLocation(
	lat: number,
	lng: number,
): Promise<Station[]> {
	await throttle();

	const solverrUrl = process.env.FLARESOLVERR_URL;

	if (solverrUrl) {
		// Get valid Cloudflare cookies, then POST with them
		const { cookies, userAgent } = await getCloudfareCookies(solverrUrl);
		const json = await graphqlPost(lat, lng, {
			Cookie: cookies,
			"User-Agent": userAgent,
			// gbcsrf appears to only need to be present; value is not validated server-side
			gbcsrf: `1.${Math.random().toString(36).slice(2, 14)}`,
		});

		if (json.errors?.length) {
			// Cookies may have expired mid-session — invalidate cache and retry once
			cachedCookies = null;
			const { cookies: fresh, userAgent: freshUA } = await getCloudfareCookies(solverrUrl);
			const retry = await graphqlPost(lat, lng, {
				Cookie: fresh,
				"User-Agent": freshUA,
				gbcsrf: `1.${Math.random().toString(36).slice(2, 14)}`,
			});
			if (retry.errors?.length) {
				throw new Error(`GasBuddy GraphQL: ${retry.errors.map((e) => e.message).join(", ")}`);
			}
			return mapResults(retry.data.locationBySearchTerm);
		}

		return mapResults(json.data.locationBySearchTerm);
	}

	// No FlareSolverr — try direct (works if Cloudflare isn't blocking)
	const json = await graphqlPost(lat, lng);
	if (json.errors?.length) {
		throw new Error(`GasBuddy GraphQL: ${json.errors.map((e) => e.message).join(", ")}`);
	}
	return mapResults(json.data.locationBySearchTerm);
}
