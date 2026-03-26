import { Database } from "bun:sqlite";

export interface StationRow {
	id: string;
	name: string;
	lat: number;
	lng: number;
	address: string | null;
	city: string | null;
	state: string | null;
	zip: string | null;
	prices_json: string;
	fetched_at: number;
}

export interface Price {
	nickname: string;
	formattedPrice: string | null;
	postedTime: string | null;
}

export interface Station {
	id: string;
	name: string;
	lat: number;
	lng: number;
	address: string | null;
	city: string | null;
	state: string | null;
	zip: string | null;
	prices: Price[];
	fetchedAt: number;
}

let _db: Database | null = null;

export function getDb(): Database {
	if (_db) return _db;

	_db = new Database(process.env.DB_PATH ?? "./gastrack.db");
	_db.exec("PRAGMA journal_mode = WAL");
	_db.exec("PRAGMA foreign_keys = ON");
	migrate(_db);
	return _db;
}

function migrate(db: Database): void {
	db.exec(`
    CREATE TABLE IF NOT EXISTS stations (
      id          TEXT PRIMARY KEY,
      name        TEXT NOT NULL,
      lat         REAL NOT NULL,
      lng         REAL NOT NULL,
      address     TEXT,
      city        TEXT,
      state       TEXT,
      zip         TEXT,
      prices_json TEXT NOT NULL,
      fetched_at  INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_stations_lat_lng ON stations (lat, lng);

    CREATE TABLE IF NOT EXISTS prefetch_cells (
      cell_key   TEXT PRIMARY KEY,
      fetched_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS api_keys (
      key        TEXT PRIMARY KEY,
      email      TEXT,
      created_at INTEGER,
      last_seen  INTEGER
    );

    CREATE TABLE IF NOT EXISTS rate_limit (
      key    TEXT NOT NULL,
      window INTEGER NOT NULL,
      count  INTEGER DEFAULT 0,
      PRIMARY KEY (key, window)
    );

    CREATE TABLE IF NOT EXISTS eia_averages (
      state      TEXT PRIMARY KEY,
      regular    REAL,
      period     TEXT NOT NULL,
      fetched_at INTEGER NOT NULL
    );
  `);
}

export function rowToStation(row: StationRow): Station {
	return {
		id: row.id,
		name: row.name,
		lat: row.lat,
		lng: row.lng,
		address: row.address,
		city: row.city,
		state: row.state,
		zip: row.zip,
		prices: JSON.parse(row.prices_json) as Price[],
		fetchedAt: row.fetched_at,
	};
}

export function upsertStations(stations: Station[]): void {
	const db = getDb();
	const stmt = db.prepare(`
    INSERT OR REPLACE INTO stations
      (id, name, lat, lng, address, city, state, zip, prices_json, fetched_at)
    VALUES
      ($id, $name, $lat, $lng, $address, $city, $state, $zip, $prices_json, $fetched_at)
  `);

	const upsertMany = db.transaction((rows: Station[]) => {
		for (const s of rows) {
			stmt.run({
				$id: s.id,
				$name: s.name,
				$lat: s.lat,
				$lng: s.lng,
				$address: s.address ?? null,
				$city: s.city ?? null,
				$state: s.state ?? null,
				$zip: s.zip ?? null,
				$prices_json: JSON.stringify(s.prices),
				$fetched_at: s.fetchedAt,
			});
		}
	});

	upsertMany(stations);
}

export function queryStationsInBbox(
	minLat: number,
	minLng: number,
	maxLat: number,
	maxLng: number,
): Station[] {
	const db = getDb();
	const rows = db
		.query<StationRow, [number, number, number, number]>(
			`SELECT * FROM stations
       WHERE lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?`,
		)
		.all(minLat, maxLat, minLng, maxLng);
	return rows.map(rowToStation);
}

export function queryStationsNear(
	lat: number,
	lng: number,
	radiusKm: number,
): Station[] {
	// Use a bounding box approximation (1 deg lat ≈ 111km)
	const latDelta = radiusKm / 111;
	const lngDelta = radiusKm / (111 * Math.cos((lat * Math.PI) / 180));
	return queryStationsInBbox(
		lat - latDelta,
		lng - lngDelta,
		lat + latDelta,
		lng + lngDelta,
	);
}

export function isCellFresh(cellKey: string, ttlMs: number): boolean {
	const db = getDb();
	const row = db
		.query<{ fetched_at: number }, [string]>(
			"SELECT fetched_at FROM prefetch_cells WHERE cell_key = ?",
		)
		.get(cellKey);
	if (!row) return false;
	return Date.now() - row.fetched_at < ttlMs;
}

export function markCellFetched(cellKey: string): void {
	const db = getDb();
	db.run(
		"INSERT OR REPLACE INTO prefetch_cells (cell_key, fetched_at) VALUES (?, ?)",
		[cellKey, Date.now()],
	);
}

export function getCacheStats(): {
	cachedStations: number;
	oldestFetch: number | null;
	newestFetch: number | null;
} {
	const db = getDb();
	const row = db
		.query<
			{ count: number; oldest: number | null; newest: number | null },
			[]
		>("SELECT COUNT(*) as count, MIN(fetched_at) as oldest, MAX(fetched_at) as newest FROM stations")
		.get();
	return {
		cachedStations: row?.count ?? 0,
		oldestFetch: row?.oldest ?? null,
		newestFetch: row?.newest ?? null,
	};
}

export function lookupApiKey(key: string): boolean {
	const db = getDb();
	const row = db
		.query<{ key: string }, [string]>(
			"SELECT key FROM api_keys WHERE key = ?",
		)
		.get(key);
	if (row) {
		db.run("UPDATE api_keys SET last_seen = ? WHERE key = ?", [
			Date.now(),
			key,
		]);
	}
	return row !== null;
}

export function createApiKey(email: string | null): string {
	const db = getDb();
	const key = `gt_${crypto.randomUUID().replace(/-/g, "")}`;
	db.run(
		"INSERT INTO api_keys (key, email, created_at) VALUES (?, ?, ?)",
		[key, email, Date.now()],
	);
	return key;
}

// Returns true if under limit, false if rate limited
export function checkRateLimit(key: string): boolean {
	const db = getDb();
	const now = Date.now();
	const currentWindow = Math.floor(now / 60_000);
	const cutoff = currentWindow - 15; // last 15 minute buckets

	// Lazily expire old buckets
	db.run(
		"DELETE FROM rate_limit WHERE key = ? AND window < ?",
		[key, cutoff],
	);

	// Increment current bucket
	db.run(
		`INSERT INTO rate_limit (key, window, count) VALUES (?, ?, 1)
     ON CONFLICT (key, window) DO UPDATE SET count = count + 1`,
		[key, currentWindow],
	);

	// Sum the last 60 buckets
	const row = db
		.query<{ total: number }, [string, number]>(
			"SELECT SUM(count) as total FROM rate_limit WHERE key = ? AND window >= ?",
		)
		.get(key, cutoff);

	return (row?.total ?? 0) <= 300;
}

const EIA_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 1 week

export interface EIAAverage {
	state: string;
	regular: number | null;
	period: string;
	fetchedAt: number;
}

export function getEIAAverages(): EIAAverage[] {
	const db = getDb();
	return db
		.query<
			{ state: string; regular: number | null; period: string; fetched_at: number },
			[]
		>("SELECT state, regular, period, fetched_at FROM eia_averages")
		.all()
		.map((r) => ({ state: r.state, regular: r.regular, period: r.period, fetchedAt: r.fetched_at }));
}

export function areEIAAveragesFresh(): boolean {
	const db = getDb();
	const row = db
		.query<{ fetched_at: number }, []>(
			"SELECT MIN(fetched_at) as fetched_at FROM eia_averages",
		)
		.get();
	if (!row?.fetched_at) return false;
	return Date.now() - row.fetched_at < EIA_TTL_MS;
}

export function upsertEIAAverages(averages: EIAAverage[]): void {
	const db = getDb();
	const stmt = db.prepare(
		"INSERT OR REPLACE INTO eia_averages (state, regular, period, fetched_at) VALUES ($state, $regular, $period, $fetched_at)",
	);
	const upsertMany = db.transaction((rows: EIAAverage[]) => {
		for (const a of rows) {
			stmt.run({ $state: a.state, $regular: a.regular, $period: a.period, $fetched_at: a.fetchedAt });
		}
	});
	upsertMany(averages);
}
