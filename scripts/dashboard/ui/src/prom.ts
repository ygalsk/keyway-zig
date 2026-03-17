// Prometheus text format parser + rate/quantile computation
// Replaces client-side metric simulation with real /metrics scraping.

type Labels = Record<string, string>;

interface Sample {
  name: string;
  labels: Labels;
  value: number;
}

interface Scrape {
  ts: number;
  samples: Map<string, number>; // full line key → value
  parsed: Sample[];
}

const SCRAPE_RING_SIZE = 60;
const scrapes: Scrape[] = [];

// ─── Parsing ─────────────────────────────────────────────

function parseLine(line: string): Sample | null {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith("#")) return null;

  // metric_name{label="val",...} value
  // metric_name value
  const braceIdx = trimmed.indexOf("{");
  let name: string;
  let labels: Labels = {};
  let rest: string;

  if (braceIdx >= 0) {
    name = trimmed.slice(0, braceIdx);
    const closeIdx = trimmed.indexOf("}", braceIdx);
    if (closeIdx < 0) return null;
    const labelStr = trimmed.slice(braceIdx + 1, closeIdx);
    for (const pair of labelStr.split(",")) {
      const eq = pair.indexOf("=");
      if (eq < 0) continue;
      const k = pair.slice(0, eq);
      let v = pair.slice(eq + 1);
      if (v.startsWith('"') && v.endsWith('"')) v = v.slice(1, -1);
      labels[k] = v;
    }
    rest = trimmed.slice(closeIdx + 1).trim();
  } else {
    const spaceIdx = trimmed.indexOf(" ");
    if (spaceIdx < 0) return null;
    name = trimmed.slice(0, spaceIdx);
    rest = trimmed.slice(spaceIdx + 1).trim();
  }

  const value = parseFloat(rest);
  if (isNaN(value)) return null;
  return { name, labels, value };
}

function sampleKey(s: Sample): string {
  const labelParts = Object.entries(s.labels)
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([k, v]) => `${k}="${v}"`)
    .join(",");
  return labelParts ? `${s.name}{${labelParts}}` : s.name;
}

// ─── Ingestion ───────────────────────────────────────────

export function ingestScrape(text: string): void {
  const samples = new Map<string, number>();
  const parsed: Sample[] = [];

  for (const line of text.split("\n")) {
    const s = parseLine(line);
    if (!s) continue;
    samples.set(sampleKey(s), s.value);
    parsed.push(s);
  }

  scrapes.push({ ts: Date.now(), samples, parsed });
  if (scrapes.length > SCRAPE_RING_SIZE) scrapes.shift();
}

// ─── Queries ─────────────────────────────────────────────

function latest(): Scrape | null {
  return scrapes.length > 0 ? scrapes[scrapes.length - 1] : null;
}

function matchesSelector(sample: Sample, selector?: Labels | ((labels: Labels) => boolean)): boolean {
  if (!selector) return true;
  if (typeof selector === "function") return selector(sample.labels);
  for (const [k, v] of Object.entries(selector)) {
    if (sample.labels[k] !== v) return false;
  }
  return true;
}

/** Current gauge value. Sums across all label sets matching the selector. */
export function gauge(metric: string, selector?: Labels): number {
  const s = latest();
  if (!s) return 0;
  let total = 0;
  for (const sample of s.parsed) {
    if (sample.name === metric && matchesSelector(sample, selector)) {
      total += sample.value;
    }
  }
  return total;
}

/** Per-second rate of a counter over the scrape window. */
export function rate(metric: string, selector?: Labels | ((labels: Labels) => boolean)): number {
  if (scrapes.length < 2) return 0;
  const first = scrapes[0];
  const last = scrapes[scrapes.length - 1];
  const dt = (last.ts - first.ts) / 1000;
  if (dt <= 0) return 0;

  let firstSum = 0;
  let lastSum = 0;
  for (const s of first.parsed) {
    if (s.name === metric && matchesSelector(s, selector)) firstSum += s.value;
  }
  for (const s of last.parsed) {
    if (s.name === metric && matchesSelector(s, selector)) lastSum += s.value;
  }

  return Math.max(0, (lastSum - firstSum) / dt);
}

/** Compute quantile from histogram buckets (linear interpolation). */
export function histogramQuantile(q: number, metric: string): number {
  const s = latest();
  if (!s) return 0;

  // Collect bucket entries: {le, count}
  const bucketName = metric + "_bucket";
  const buckets: { le: number; count: number }[] = [];
  let totalCount = 0;

  for (const sample of s.parsed) {
    if (sample.name === bucketName && sample.labels.le) {
      const le = sample.labels.le === "+Inf" ? Infinity : parseFloat(sample.labels.le);
      if (!isNaN(le)) buckets.push({ le, count: sample.value });
    }
    if (sample.name === metric + "_count") {
      totalCount = sample.value;
    }
  }

  if (buckets.length === 0 || totalCount === 0) return 0;
  buckets.sort((a, b) => a.le - b.le);

  const target = q * totalCount;

  // Linear interpolation between bucket boundaries
  let prevLe = 0;
  let prevCount = 0;
  for (const b of buckets) {
    if (b.count >= target) {
      if (b.le === Infinity) return prevLe;
      const fraction = (target - prevCount) / Math.max(1, b.count - prevCount);
      return prevLe + (b.le - prevLe) * fraction;
    }
    prevLe = b.le === Infinity ? prevLe : b.le;
    prevCount = b.count;
  }

  return prevLe;
}

/** Get rate at each scrape point (for sparklines). */
export function rateHistory(metric: string, selector?: Labels | ((labels: Labels) => boolean)): number[] {
  if (scrapes.length < 2) return [];
  const data: number[] = [];
  for (let i = 1; i < scrapes.length; i++) {
    const prev = scrapes[i - 1];
    const curr = scrapes[i];
    const dt = (curr.ts - prev.ts) / 1000;
    if (dt <= 0) { data.push(0); continue; }

    let prevSum = 0;
    let currSum = 0;
    for (const s of prev.parsed) {
      if (s.name === metric && matchesSelector(s, selector)) prevSum += s.value;
    }
    for (const s of curr.parsed) {
      if (s.name === metric && matchesSelector(s, selector)) currSum += s.value;
    }
    data.push(Math.max(0, (currSum - prevSum) / dt));
  }
  return data;
}

/** Get gauge value at each scrape point (for sparklines). */
export function gaugeHistory(metric: string, selector?: Labels): number[] {
  return scrapes.map(s => {
    let total = 0;
    for (const sample of s.parsed) {
      if (sample.name === metric && matchesSelector(sample, selector)) {
        total += sample.value;
      }
    }
    return total;
  });
}

/** Number of scrapes collected so far. */
export function scrapeCount(): number {
  return scrapes.length;
}

/** Extract unique values for a given label key from the latest scrape. */
export function uniqueLabels(metric: string, labelKey: string): string[] {
  const s = latest();
  if (!s) return [];
  const vals = new Set<string>();
  for (const sample of s.parsed) {
    if (sample.name === metric && sample.labels[labelKey] !== undefined) {
      vals.add(sample.labels[labelKey]);
    }
  }
  return Array.from(vals).sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
}
