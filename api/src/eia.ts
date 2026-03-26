// EIA duoarea code -> 2-letter state abbreviation
const DUOAREA_TO_STATE: Record<string, string> = {
	SAK: "AK", SAL: "AL", SAR: "AR", SAZ: "AZ", SCA: "CA",
	SCO: "CO", SCT: "CT", SDC: "DC", SDE: "DE", SFL: "FL",
	SGA: "GA", SHI: "HI", SIA: "IA", SID: "ID", SIL: "IL",
	SIN: "IN", SKS: "KS", SKY: "KY", SLA: "LA", SMA: "MA",
	SMD: "MD", SME: "ME", SMI: "MI", SMN: "MN", SMO: "MO",
	SMS: "MS", SMT: "MT", SNC: "NC", SND: "ND", SNE: "NE",
	SNH: "NH", SNJ: "NJ", SNM: "NM", SNV: "NV", SNY: "NY",
	SOH: "OH", SOK: "OK", SOR: "OR", SPA: "PA", SRI: "RI",
	SSC: "SC", SSD: "SD", STN: "TN", STX: "TX", SUT: "UT",
	SVA: "VA", SVT: "VT", SWA: "WA", SWI: "WI", SWV: "WV",
	SWY: "WY",
};

export interface StateAverage {
	state: string;
	regular: number | null;
	period: string; // ISO date string of the week
}

interface EIADataRow {
	period: string;
	duoarea: string;
	product: string;
	value: number | null;
}

interface EIAResponse {
	response: {
		data: EIADataRow[];
	};
}

export async function fetchStateAverages(): Promise<StateAverage[]> {
	const apiKey = process.env.EIA_API_KEY;
	if (!apiKey) throw new Error("EIA_API_KEY not set");

	const params = new URLSearchParams({
		api_key: apiKey,
		frequency: "weekly",
		"data[]": "value",
		"facets[product][]": "EPM0", // regular unleaded
		"sort[0][column]": "period",
		"sort[0][direction]": "desc",
		length: "60",
	});

	const res = await fetch(
		`https://api.eia.gov/v2/petroleum/pri/gnd/data/?${params}`,
	);
	if (!res.ok) {
		throw new Error(`EIA API returned ${res.status}`);
	}

	const json = (await res.json()) as EIAResponse;
	const rows = json.response.data;

	// Keep only the most recent entry per state
	const latestByState = new Map<string, EIADataRow>();
	for (const row of rows) {
		const state = DUOAREA_TO_STATE[row.duoarea];
		if (!state) continue;
		const existing = latestByState.get(state);
		if (!existing || row.period > existing.period) {
			latestByState.set(state, row);
		}
	}

	return Array.from(latestByState.entries()).map(([state, row]) => ({
		state,
		regular: row.value,
		period: row.period,
	}));
}
