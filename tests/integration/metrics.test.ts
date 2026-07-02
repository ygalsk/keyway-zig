// /metrics label contract — the dashboard's metrics panel parses these
// families/labels out of the Prometheus exposition text (#118). This test
// pins the CURRENT actual label set so a format change breaks CI instead of
// silently breaking the dashboard.
//
// Note: #119 may later refine what the `route` label carries (it's currently
// the matched route *pattern*, e.g. "/test/hello", or "" when no route
// matched). Update this test if that changes.

import { describe, test, expect } from "bun:test";

const base = () => globalThis.__KEYWAY_BASE;

describe("metrics", () => {
  test("GET /metrics exposes the families and labels the dashboard consumes", async () => {
    // Generate some traffic first so the counters/histograms have series.
    await fetch(`${base()}/test/hello`);
    await fetch(`${base()}/test/json`);

    const res = await fetch(`${base()}/metrics`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/plain");

    const body = await res.text();

    // -- keyway_http_requests_total: worker_id, method, status, route --
    expect(body).toContain("# TYPE keyway_http_requests_total counter");
    expect(body).toMatch(
      /keyway_http_requests_total\{worker_id="0",method="GET",status="200",route="\/test\/hello"\} \d+/,
    );
    expect(body).toMatch(
      /keyway_http_requests_total\{worker_id="0",method="GET",status="200",route="\/test\/json"\} \d+/,
    );

    // -- request-duration histogram: worker_id, route, standard buckets --
    expect(body).toContain(
      "# TYPE keyway_http_request_duration_seconds histogram",
    );
    expect(body).toMatch(
      /keyway_http_request_duration_seconds_bucket\{le="\+Inf",worker_id="0",route="\/test\/hello"\} \d+/,
    );
    expect(body).toMatch(
      /keyway_http_request_duration_seconds_count\{worker_id="0",route="\/test\/hello"\} \d+/,
    );

    // -- gauges: connections_active and script_generation (#117) --
    expect(body).toContain("# TYPE keyway_connections_active gauge");
    expect(body).toMatch(/keyway_connections_active\{worker_id="0"\} \d+/);

    expect(body).toContain("# TYPE keyway_script_generation gauge");
    expect(body).toContain(
      "# HELP keyway_script_generation Per-worker Lua script generation, incremented on each successful hot reload",
    );
  });
});
