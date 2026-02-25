-- Keyway Handlers
-- Uses organic HttpExchange API - ctx is a single Zig struct with declarative interface
if jit then
    jit.opt.start(
        "maxtrace=10000",      -- Allow more traces (default: 1000)
        "maxrecord=20000",     -- Allow longer traces (default: 4000)
        "maxirconst=10000",    -- More IR constants (default: 500)
        "maxmcode=4096",       -- Bigger machine code cache in KB (default: 512)
        "maxsnap=1000",        -- More snapshots (default: 500)
        "hotexit=10",          -- Lower hotness threshold (default: 56)
        "hotloop=40",          -- Lower loop hotness (default: 56)
        "tryside=4"            -- Trace side exits (default: 4)

    )
    collectgarbage("setpause", 100)
    collectgarbage("setstepmul", 500)
end

-- Landing page HTML — built once at module load, zero per-request allocation
local landing_page = [=[
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Keyway — High-Performance HTTP Engine</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    :root {
      --bg: #0a0a0f;
      --surface: #13131a;
      --border: #1e1e2e;
      --text: #e2e2f0;
      --muted: #7a7a9a;
      --accent: #7c6af5;
      --accent2: #4fc3f7;
      --green: #4ade80;
      --orange: #fb923c;
    }
    body {
      background: var(--bg);
      color: var(--text);
      font-family: system-ui, -apple-system, sans-serif;
      line-height: 1.6;
      min-height: 100vh;
    }
    a { color: var(--accent2); text-decoration: none; }
    a:hover { text-decoration: underline; }
    code, pre { font-family: 'Fira Code', 'Cascadia Code', monospace; }

    .container { max-width: 860px; margin: 0 auto; padding: 0 1.5rem; }

    /* Hero */
    .hero {
      padding: 5rem 0 3rem;
      text-align: center;
      border-bottom: 1px solid var(--border);
    }
    .hero h1 {
      font-size: clamp(3rem, 8vw, 5rem);
      font-weight: 800;
      letter-spacing: -0.03em;
      background: linear-gradient(135deg, var(--accent) 0%, var(--accent2) 100%);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      background-clip: text;
      line-height: 1.1;
      margin-bottom: 1rem;
    }
    .hero .tagline {
      font-size: 1.2rem;
      color: var(--muted);
      max-width: 520px;
      margin: 0 auto 2rem;
    }
    .badges {
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem;
      justify-content: center;
    }
    .badge {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 999px;
      padding: 0.25rem 0.75rem;
      font-size: 0.8rem;
      font-family: monospace;
      color: var(--accent2);
    }

    /* Sections */
    section { padding: 3rem 0; border-bottom: 1px solid var(--border); }
    section:last-child { border-bottom: none; }
    h2 {
      font-size: 1.4rem;
      font-weight: 700;
      color: var(--text);
      margin-bottom: 1.25rem;
    }
    h2 .label {
      font-size: 0.7rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.1em;
      color: var(--accent);
      display: block;
      margin-bottom: 0.25rem;
    }

    /* Pipeline */
    .pipeline {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 1.5rem;
      display: flex;
      flex-wrap: wrap;
      gap: 0.35rem;
      align-items: center;
      justify-content: center;
    }
    .pipeline-step {
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 0.4rem 0.75rem;
      font-size: 0.8rem;
      font-family: monospace;
      color: var(--text);
      white-space: nowrap;
    }
    .pipeline-arrow {
      color: var(--muted);
      font-size: 0.9rem;
      user-select: none;
    }

    /* Layers table */
    .layers {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.9rem;
    }
    .layers th {
      text-align: left;
      padding: 0.5rem 0.75rem;
      color: var(--muted);
      font-weight: 600;
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      border-bottom: 1px solid var(--border);
    }
    .layers td {
      padding: 0.6rem 0.75rem;
      border-bottom: 1px solid var(--border);
    }
    .layers tr:last-child td { border-bottom: none; }
    .layers td:first-child { font-family: monospace; color: var(--accent2); }
    .layers td:last-child { color: var(--muted); }

    /* Routes */
    .routes { display: flex; flex-direction: column; gap: 0.5rem; }
    .route {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 0.6rem 1rem;
      font-size: 0.88rem;
    }
    .method {
      font-family: monospace;
      font-weight: 700;
      font-size: 0.75rem;
      padding: 0.15rem 0.5rem;
      border-radius: 4px;
      min-width: 46px;
      text-align: center;
    }
    .method.get  { background: #0d3321; color: var(--green); }
    .method.post { background: #2d1e0d; color: var(--orange); }
    .route-path { font-family: monospace; color: var(--text); flex: 1; }
    .route-desc { color: var(--muted); font-size: 0.8rem; }
    .route a { color: inherit; }

    /* Code block */
    .code-block {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 10px;
      overflow: hidden;
    }
    .code-header {
      padding: 0.5rem 1rem;
      border-bottom: 1px solid var(--border);
      font-size: 0.75rem;
      color: var(--muted);
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }
    .code-header::before {
      content: '';
      width: 8px; height: 8px;
      background: var(--accent);
      border-radius: 50%;
    }
    .code-block pre {
      padding: 1.25rem;
      font-size: 0.85rem;
      overflow-x: auto;
      line-height: 1.7;
      color: var(--text);
    }
    .kw { color: #c792ea; }
    .fn { color: var(--accent2); }
    .str { color: var(--green); }
    .num { color: var(--orange); }
    .cm { color: var(--muted); font-style: italic; }

    /* Footer */
    footer {
      padding: 2rem 0;
      text-align: center;
      color: var(--muted);
      font-size: 0.85rem;
    }
    footer a { color: var(--muted); }
    footer a:hover { color: var(--accent2); }
  </style>
</head>
<body>
  <div class="container">

    <div class="hero">
      <h1>Keyway</h1>
      <p class="tagline">A high-performance HTTP engine where Zig handles execution and Lua expresses routing policy.</p>
      <div class="badges">
        <span class="badge">Zig</span>
        <span class="badge">LuaJIT</span>
        <span class="badge">io_uring</span>
        <span class="badge">libxev</span>
        <span class="badge">picohttpparser</span>
        <span class="badge">eBPF</span>
      </div>
    </div>

    <section>
      <h2><span class="label">Architecture</span>Canonical Mental Model</h2>
      <div class="pipeline">
        <span class="pipeline-step">RingBuffer</span>
        <span class="pipeline-arrow">→</span>
        <span class="pipeline-step">picohttpparser</span>
        <span class="pipeline-arrow">→</span>
        <span class="pipeline-step">Radix Router</span>
        <span class="pipeline-arrow">→</span>
        <span class="pipeline-step">HttpExchange</span>
        <span class="pipeline-arrow">→</span>
        <span class="pipeline-step">Lua</span>
        <span class="pipeline-arrow">→</span>
        <span class="pipeline-step">Response Builder</span>
        <span class="pipeline-arrow">→</span>
        <span class="pipeline-step">io_uring</span>
        <span class="pipeline-arrow">→</span>
        <span class="pipeline-step">Kernel</span>
      </div>
    </section>

    <section>
      <h2><span class="label">Design</span>Layered Responsibility</h2>
      <table class="layers">
        <thead>
          <tr><th>Layer</th><th>Responsibility</th></tr>
        </thead>
        <tbody>
          <tr><td>RingBuffer</td><td>Own bytes</td></tr>
          <tr><td>picohttpparser</td><td>Mark structure</td></tr>
          <tr><td>Radix Router</td><td>Assign meaning</td></tr>
          <tr><td>HttpExchange</td><td>Bind memory contract</td></tr>
          <tr><td>Lua</td><td>Express policy</td></tr>
          <tr><td>Response Builder</td><td>Commit I/O</td></tr>
          <tr><td>Kernel</td><td>Execute</td></tr>
        </tbody>
      </table>
    </section>

    <section>
      <h2><span class="label">API</span>Routes on this server</h2>
      <div class="routes">
        <div class="route">
          <span class="method get">GET</span>
          <a class="route-path" href="/">/</a>
          <span class="route-desc">This page (SSR landing)</span>
        </div>
        <div class="route">
          <span class="method get">GET</span>
          <a class="route-path" href="/ping">/ping</a>
          <span class="route-desc">Minimal health check</span>
        </div>
        <div class="route">
          <span class="method get">GET</span>
          <a class="route-path" href="/health">/health</a>
          <span class="route-desc">JSON health check with metadata</span>
        </div>
        <div class="route">
          <span class="method get">GET</span>
          <a class="route-path" href="/users">/users</a>
          <span class="route-desc">Mock JSON array of users</span>
        </div>
        <div class="route">
          <span class="method get">GET</span>
          <a class="route-path" href="/users/1">/users/{id}</a>
          <span class="route-desc">Dynamic param + conditional JSON</span>
        </div>
        <div class="route">
          <span class="method post">POST</span>
          <span class="route-path">/users</span>
          <span class="route-desc">Create user — 201 + Location header</span>
        </div>
        <div class="route">
          <span class="method get">GET</span>
          <a class="route-path" href="/echo/hello">/echo/{message}</a>
          <span class="route-desc">Param extraction + echo</span>
        </div>
        <div class="route">
          <span class="method get">GET</span>
          <a class="route-path" href="/debug">/debug</a>
          <span class="route-desc">Request introspection</span>
        </div>
      </div>
    </section>

    <section>
      <h2><span class="label">Philosophy</span>Lua is a Policy Language</h2>
      <div class="code-block">
        <div class="code-header">handlers.lua</div>
        <pre><code><span class="cm">-- No send(), no write(), no lifecycle calls.</span>
<span class="cm">-- Only state. Lua expresses intent, Zig commits I/O.</span>

keyway.add_route(<span class="str">"GET"</span>, <span class="str">"/users/{id}"</span>, <span class="kw">function</span>(ctx)
    <span class="kw">local</span> id   = ctx.params.id
    <span class="kw">local</span> role = (tonumber(id) <span class="kw">or</span> <span class="num">0</span>) % <span class="num">2</span> == <span class="num">0</span> <span class="kw">and</span> <span class="str">"admin"</span> <span class="kw">or</span> <span class="str">"guest"</span>

    ctx.status                    = <span class="num">200</span>
    ctx.headers[<span class="str">"Content-Type"</span>] = <span class="str">"application/json"</span>
    ctx.body                      = <span class="str">'{"id":'</span> .. id .. <span class="str">',"role":"'</span> .. role .. <span class="str">'"}'</span>
<span class="kw">end</span>)</code></pre>
      </div>
    </section>

    <footer>
      Part of the <a href="https://keystone-gateway.dev" target="_blank">keystone-gateway.dev</a> ecosystem.
    </footer>

  </div>
</body>
</html>
]=]

-- ── Landing page ─────────────────────────────────────────────────────────────

keyway.add_route("GET", "/", function(ctx)
    ctx.status = 200
    ctx.headers["Content-Type"] = "text/html; charset=utf-8"
    ctx.body = landing_page
end)

-- ── Health & status ───────────────────────────────────────────────────────────

keyway.add_route("GET", "/ping", function(ctx)
    ctx.status = 200
    ctx.body = "pong"
end)

keyway.add_route("GET", "/health", function(ctx)
    ctx.status = 200
    ctx.headers["Content-Type"] = "application/json"
    ctx.body = '{"status":"ok","engine":"keyway","runtime":"luajit"}'
end)

-- ── Users API ─────────────────────────────────────────────────────────────────

keyway.add_route("GET", "/users", function(ctx)
    ctx.status = 200
    ctx.headers["Content-Type"] = "application/json"
    ctx.body = '[{"id":1,"name":"Alice","role":"admin"},{"id":2,"name":"Bob","role":"guest"}]'
end)

keyway.add_route("GET", "/users/{id}", function(ctx)
    local id   = ctx.params.id
    local role = (tonumber(id) or 0) % 2 == 0 and "admin" or "guest"
    ctx.status = 200
    ctx.headers["Content-Type"] = "application/json"
    ctx.body = '{"id":' .. id .. ',"role":"' .. role .. '","status":"active"}'
end)

keyway.add_route("POST", "/users", function(ctx)
    local body = ctx.body
    local len  = #body
    ctx.status = 201
    ctx.headers["Content-Type"] = "application/json"
    ctx.headers["Location"]     = "/users/3"
    ctx.body = '{"id":3,"created":true,"received_bytes":' .. len .. '}'
end)

-- ── Echo & debug ──────────────────────────────────────────────────────────────

keyway.add_route("GET", "/echo/{message}", function(ctx)
    ctx.status = 200
    ctx.body = ctx.params.message
end)

keyway.add_route("GET", "/debug", function(ctx)
    local method      = ctx.method
    local path        = ctx.path
    local content_type = ctx.headers["Content-Type"] or ""
    local accept      = ctx.headers["Accept"] or ""
    ctx.status = 200
    ctx.headers["Content-Type"] = "application/json"
    ctx.body = '{"method":"' .. method .. '","path":"' .. path
           .. '","headers":{"Content-Type":"' .. content_type
           .. '","Accept":"' .. accept .. '"}}'
end)
