# METRICS_DESIGN.md — Keyway Native Metrics

> Design contract for Keyway's Prometheus-compatible metrics subsystem.
> Companion to `RING_DESIGN.md`. Intended for Claude Code handoff.

## Philosophy

Keyway is the authority on its own behavior. Metrics are computed in Zig where
the events happen — not derived client-side from sampled browser state. The
dashboard becomes a **read-only view**. Prometheus scrapes Keyway directly.
PromQL handles all aggregation, rates, and quantile computation.

No client libraries. No protobuf. Zig prints text lines in Prometheus
exposition format. That's the entire integration surface.

---

## Metric Primitives

Three structures. All lock-free. All per-worker to avoid contention, aggregated
at exposition time.

### Counter

Single `std.atomic.Value(u64)`. Monotonically increasing.

```
Increment: @atomicRmw(.Add, &counter, 1, .monotonic)
```

Use for: requests total, bytes transferred, errors total, connections accepted,
ring submissions total, ring completions total.

### Gauge

`std.atomic.Value(i64)`. Increments and decrements.

```
Up:   @atomicRmw(.Add, &gauge, 1, .monotonic)
Down: @atomicRmw(.Sub, &gauge, 1, .monotonic)
```

Use for: active connections, active Lua coroutines, ring queue depth.

### Histogram

Array of atomic u64 bucket counters + atomic u64 count + atomic u64 sum.

**Bucket bounds** are compile-time constants. On each observation:
1. Increment every bucket where `value <= bound` (cumulative, Prometheus convention)
2. Increment `_count`
3. Add to `_sum`

**Latency sum trick**: store microseconds as u64 to avoid atomic f64 CAS loops.
Convert to seconds at exposition time: `@intToFloat(f64, sum_us) / 1_000_000.0`.

**Default latency bounds (seconds)**:
```
{ 0.0005, 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 5.0, 10.0 }
```

12 buckets × 1 atomic increment each = 12 atomic ops per observation. Noise.

**Default size bounds (bytes)** for body size histograms:
```
{ 64, 256, 1024, 4096, 16384, 65536, 262144, 1048576, 4194304 }
```

---

## Metric Registry

```zig
const MetricRegistry = struct {
    workers: []WorkerMetrics,

    const WorkerMetrics = struct {
        // -- Request flow --
        http_requests_total: LabeledCounter(.{ "method", "status", "route" }),
        http_request_duration_us: Histogram,
        http_request_body_bytes: Histogram,
        http_response_body_bytes: Histogram,

        // -- io_uring / Ring buffer --
        ring_submissions_total: Counter,
        ring_completions_total: Counter,
        ring_queue_depth: Gauge,
        ring_batch_size: Histogram,

        // -- Lua runtime --
        lua_coroutines_active: Gauge,
        lua_script_duration_us: LabeledHistogram(.{ "route" }),
        lua_gc_cycles_total: Counter,

        // -- Connections --
        connections_active: Gauge,
        connections_accepted_total: Counter,
    };
};
```

`LabeledCounter` / `LabeledHistogram` are indexed by a hash of label values.
Implementation detail — can start with a fixed-size array of known routes and
expand later. Unknown routes collapse into a `route="__other__"` bucket to
bound cardinality.

---

## Exposition Endpoint

### Route

`GET /metrics` on the main listener, or a dedicated metrics-only listener on a
separate port (preferred — keeps metrics traffic off the request path and
simplifies firewall rules).

Dedicated port recommendation: `9117` (or configurable). Prometheus scrapes
this; application traffic never touches it.

### Format

Prometheus text exposition format, version 0.0.4.

```
# HELP keyway_http_requests_total Total HTTP requests handled
# TYPE keyway_http_requests_total counter
keyway_http_requests_total{worker="0",method="GET",status="200",route="/api/users"} 48293
keyway_http_requests_total{worker="0",method="POST",status="201",route="/api/users"} 1847
keyway_http_requests_total{worker="1",method="GET",status="200",route="/api/users"} 47109

# HELP keyway_http_request_duration_seconds Request latency
# TYPE keyway_http_request_duration_seconds histogram
keyway_http_request_duration_seconds_bucket{worker="0",le="0.0005"} 8102
keyway_http_request_duration_seconds_bucket{worker="0",le="0.001"} 19284
keyway_http_request_duration_seconds_bucket{worker="0",le="0.005"} 38201
keyway_http_request_duration_seconds_bucket{worker="0",le="0.01"} 41038
keyway_http_request_duration_seconds_bucket{worker="0",le="0.025"} 44921
keyway_http_request_duration_seconds_bucket{worker="0",le="0.05"} 46102
keyway_http_request_duration_seconds_bucket{worker="0",le="0.1"} 47891
keyway_http_request_duration_seconds_bucket{worker="0",le="0.25"} 48100
keyway_http_request_duration_seconds_bucket{worker="0",le="0.5"} 48200
keyway_http_request_duration_seconds_bucket{worker="0",le="1.0"} 48270
keyway_http_request_duration_seconds_bucket{worker="0",le="5.0"} 48290
keyway_http_request_duration_seconds_bucket{worker="0",le="10.0"} 48293
keyway_http_request_duration_seconds_bucket{worker="0",le="+Inf"} 48293
keyway_http_request_duration_seconds_sum{worker="0"} 892.410000
keyway_http_request_duration_seconds_count{worker="0"} 48293

# HELP keyway_ring_submissions_total Total ring buffer submissions
# TYPE keyway_ring_submissions_total counter
keyway_ring_submissions_total{worker="0"} 192847

# HELP keyway_ring_completions_total Total ring buffer completions
# TYPE keyway_ring_completions_total counter
keyway_ring_completions_total{worker="0"} 192845

# HELP keyway_ring_queue_depth Current ring buffer queue depth
# TYPE keyway_ring_queue_depth gauge
keyway_ring_queue_depth{worker="0"} 2

# HELP keyway_ring_batch_size Submissions per batch
# TYPE keyway_ring_batch_size histogram
keyway_ring_batch_size_bucket{worker="0",le="1"} 140201
keyway_ring_batch_size_bucket{worker="0",le="2"} 170432
keyway_ring_batch_size_bucket{worker="0",le="4"} 185921
keyway_ring_batch_size_bucket{worker="0",le="8"} 191002
keyway_ring_batch_size_bucket{worker="0",le="16"} 192700
keyway_ring_batch_size_bucket{worker="0",le="32"} 192847
keyway_ring_batch_size_bucket{worker="0",le="+Inf"} 192847
keyway_ring_batch_size_sum{worker="0"} 321049
keyway_ring_batch_size_count{worker="0"} 192847

# HELP keyway_lua_coroutines_active Active Lua coroutines
# TYPE keyway_lua_coroutines_active gauge
keyway_lua_coroutines_active{worker="0"} 14

# HELP keyway_lua_script_duration_seconds Lua script execution time
# TYPE keyway_lua_script_duration_seconds histogram
keyway_lua_script_duration_seconds_bucket{worker="0",route="/api/users",le="0.001"} 38201
# ... (same bucket structure as request duration)

# HELP keyway_connections_active Current active connections
# TYPE keyway_connections_active gauge
keyway_connections_active{worker="0"} 42

# HELP keyway_connections_accepted_total Total accepted connections
# TYPE keyway_connections_accepted_total counter
keyway_connections_accepted_total{worker="0"} 98201
```

### Content-Type

```
Content-Type: text/plain; version=0.0.4; charset=utf-8
```

### Implementation

A single Zig function iterates `MetricRegistry.workers`, writes text lines into
a stack-allocated or arena-allocated buffer. No heap allocation per scrape.

Pseudocode:
```zig
fn serveMetrics(registry: *MetricRegistry, writer: anytype) !void {
    // For each metric family:
    //   Write # HELP line
    //   Write # TYPE line
    //   For each worker:
    //     For each label combination:
    //       Write metric line with current atomic value
    //
    // Histograms: iterate bounds, write _bucket lines,
    // then _sum (convert us -> seconds), then _count
}
```

---

## Instrumentation Points

Where atomic operations are inserted in the existing Keyway request lifecycle:

| Event | Location | Metrics touched |
|-------|----------|-----------------|
| Connection accepted | accept loop | `connections_accepted_total++`, `connections_active++` |
| Request parsed | after header parse | Start `request_timer = timestamp()` |
| Lua script dispatched | coroutine creation | `lua_coroutines_active++`, start `lua_timer` |
| Ring submission | SQ append in ring | `ring_submissions_total += batch_size`, observe `ring_batch_size`, update `ring_queue_depth` |
| Ring completion | CQ drain | `ring_completions_total += completed`, update `ring_queue_depth` |
| Lua script returns | coroutine completion | `lua_coroutines_active--`, observe `lua_script_duration_us` |
| Response written | after flush | observe `request_duration_us`, observe `response_body_bytes`, `http_requests_total++` |
| Connection closed | cleanup | `connections_active--` |

**Cost per request**: ~30-40 atomic operations total. Sub-microsecond overhead.

---

## Cardinality Control

Unbounded label cardinality kills Prometheus. Keyway controls this:

- **route**: Known routes from Lua config. Unknown routes → `route="__other__"`.
  Maximum cardinality = number of registered routes + 1.
- **method**: Only observed HTTP methods. Practically bounded at ~5.
- **status**: 3-digit status codes. Bounded by HTTP spec, practically ~10.
- **worker**: Fixed at startup. Number of worker threads.

**Hard limit**: If a label combination set exceeds 1000 series, stop creating
new label combinations and increment a `keyway_metrics_overflow_total` counter.

---

## Prometheus Configuration

Minimal `prometheus.yml` addition:

```yaml
scrape_configs:
  - job_name: 'keyway'
    scrape_interval: 15s
    static_configs:
      - targets: ['keyway-host:9117']
```

Or with service discovery if running multiple Keyway instances.

---

## Key PromQL Queries

These replace everything that `state.ts` and `computeAllWorkerStats()` were
doing client-side:

### Request rate (RPS)
```promql
sum(rate(keyway_http_requests_total[5m]))
```

### Request rate per route
```promql
sum by (route) (rate(keyway_http_requests_total[5m]))
```

### Latency percentiles (p50, p95, p99)
```promql
histogram_quantile(0.50, sum(rate(keyway_http_request_duration_seconds_bucket[5m])) by (le))
histogram_quantile(0.95, sum(rate(keyway_http_request_duration_seconds_bucket[5m])) by (le))
histogram_quantile(0.99, sum(rate(keyway_http_request_duration_seconds_bucket[5m])) by (le))
```

### Latency percentiles per route
```promql
histogram_quantile(0.99, sum by (route, le) (rate(keyway_http_request_duration_seconds_bucket[5m])))
```

### Error rate
```promql
sum(rate(keyway_http_requests_total{status=~"5.."}[5m]))
  /
sum(rate(keyway_http_requests_total[5m]))
```

### Active connections per worker
```promql
keyway_connections_active
```

### Worker imbalance detection
```promql
max(rate(keyway_http_requests_total[5m])) by (worker)
  /
avg(rate(keyway_http_requests_total[5m])) by (worker)
```

### Ring buffer efficiency (average batch size)
```promql
rate(keyway_ring_batch_size_sum[5m]) / rate(keyway_ring_batch_size_count[5m])
```

### Ring buffer backpressure
```promql
keyway_ring_queue_depth
```

### Lua coroutine saturation
```promql
keyway_lua_coroutines_active
```

### Lua script latency per route
```promql
histogram_quantile(0.99, sum by (route, le) (rate(keyway_lua_script_duration_seconds_bucket[5m])))
```

---

## What Dies in JS

The following are deleted entirely — not refactored, not wrapped:

- `state.ts` — the 500-entry traffic ring buffer, 60-entry metric history,
  sparkline data arrays
- `computeAllWorkerStats()` in `workers.tsx` — client-side p50/p95/p99
  derivation from the traffic buffer
- Any WebSocket/polling mechanism that streams raw request events to the browser
  for client-side aggregation

The dashboard becomes a PromQL query frontend. It reads from Prometheus (or
directly from `/metrics` for instantaneous gauges). Historical data, rates,
percentiles — all PromQL.

---

## Coroot Integration

Keyway's `/metrics` endpoint is directly compatible with Coroot's Prometheus
scraping. Since Coroot is already running in the infrastructure, Keyway metrics
appear in Coroot dashboards alongside the existing MySQL exporters and other
services with zero additional setup beyond adding the scrape target.

---

## Future Extensions (Out of Scope for Initial Implementation)

- **OpenMetrics format**: Prometheus is converging on OpenMetrics. Exposition
  format is nearly identical; switching later is trivial.
- **Exemplars**: Attach trace IDs to histogram observations for drill-down.
- **Push gateway**: For short-lived Keyway processes (unlikely but possible).
- **Control plane metrics**: Admin operations counter, config reload events.
  These belong to the control plane design, not this document.

---

## Implementation Order

1. Define metric structs in Zig (Counter, Gauge, Histogram)
2. Create MetricRegistry, allocate per-worker
3. Add instrumentation at each lifecycle point (see table above)
4. Implement `/metrics` exposition endpoint on dedicated port
5. Verify with `curl localhost:9117/metrics` and `promtool check metrics`
6. Add Keyway scrape target to Prometheus config
7. Build PromQL queries, verify in Prometheus UI
8. Delete `state.ts`, `computeAllWorkerStats()`, client-side metric code
9. Rewire dashboard to query Prometheus
