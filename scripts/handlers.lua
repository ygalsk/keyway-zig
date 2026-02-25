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

-- Module-level state (per-worker, no sharing)
local request_count = 0
local start_time = os.time()

-- Landing page HTML — built once at module load, zero per-request allocation
local landing_page = [=[
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Keyway — Interactive Showcase</title>
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
      --red: #f87171;
      --yellow: #fbbf24;
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

    .container { max-width: 920px; margin: 0 auto; padding: 0 1.5rem; }

    /* Hero */
    .hero {
      padding: 4rem 0 2.5rem;
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
      margin-bottom: 0.75rem;
    }
    .hero .tagline {
      font-size: 1.15rem;
      color: var(--muted);
      max-width: 540px;
      margin: 0 auto 1.5rem;
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
    section { padding: 2.5rem 0; border-bottom: 1px solid var(--border); }
    section:last-child { border-bottom: none; }
    h2 {
      font-size: 1.3rem;
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

    /* Dashboard cards */
    .dashboard {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
      gap: 1rem;
    }
    .card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 1.25rem;
    }
    .card-title {
      font-size: 0.75rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      color: var(--muted);
      margin-bottom: 0.5rem;
    }
    .card-value {
      font-size: 1.6rem;
      font-weight: 700;
      font-family: monospace;
      color: var(--accent2);
    }
    .card-sub {
      font-size: 0.8rem;
      color: var(--muted);
      margin-top: 0.25rem;
    }
    .sparkline {
      display: flex;
      align-items: flex-end;
      gap: 2px;
      height: 24px;
      margin-top: 0.5rem;
    }
    .sparkline .bar {
      width: 4px;
      background: var(--accent);
      border-radius: 2px;
      min-height: 2px;
      transition: height 0.3s;
    }

    /* Tabs */
    .tabs {
      display: flex;
      flex-wrap: wrap;
      gap: 0.25rem;
      margin-bottom: 1rem;
      border-bottom: 1px solid var(--border);
      padding-bottom: 0.5rem;
    }
    .tab-btn {
      background: none;
      border: 1px solid transparent;
      border-radius: 6px;
      padding: 0.35rem 0.75rem;
      font-size: 0.82rem;
      color: var(--muted);
      cursor: pointer;
      font-family: inherit;
      transition: all 0.15s;
    }
    .tab-btn:hover { color: var(--text); background: var(--surface); }
    .tab-btn.active {
      color: var(--accent2);
      background: var(--surface);
      border-color: var(--border);
    }
    .tab-panel { display: none; }
    .tab-panel.active { display: block; }

    /* Playground controls */
    .btn-row { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-bottom: 1rem; }
    .btn {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 0.4rem 0.85rem;
      font-size: 0.82rem;
      color: var(--text);
      cursor: pointer;
      font-family: monospace;
      transition: all 0.15s;
    }
    .btn:hover { border-color: var(--accent); color: var(--accent2); }
    .btn.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
    .btn.primary:hover { opacity: 0.9; }
    .input-row { display: flex; gap: 0.5rem; margin-bottom: 1rem; align-items: center; }
    .input-row input, .input-row textarea {
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 0.4rem 0.75rem;
      font-size: 0.85rem;
      color: var(--text);
      font-family: monospace;
      flex: 1;
    }
    .input-row input:focus, .input-row textarea:focus {
      outline: none;
      border-color: var(--accent);
    }
    textarea.body-input {
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 0.5rem 0.75rem;
      font-size: 0.85rem;
      color: var(--text);
      font-family: monospace;
      width: 100%;
      min-height: 60px;
      resize: vertical;
      margin-bottom: 0.75rem;
    }
    textarea.body-input:focus { outline: none; border-color: var(--accent); }

    /* Response viewer */
    .response-viewer {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 8px;
      overflow: hidden;
      margin-top: 0.75rem;
    }
    .response-header {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      padding: 0.6rem 1rem;
      border-bottom: 1px solid var(--border);
      font-size: 0.8rem;
    }
    .status-badge {
      padding: 0.15rem 0.5rem;
      border-radius: 4px;
      font-family: monospace;
      font-weight: 700;
      font-size: 0.75rem;
    }
    .status-2xx { background: #0d3321; color: var(--green); }
    .status-4xx { background: #3d2d0d; color: var(--yellow); }
    .status-5xx { background: #3d0d0d; color: var(--red); }
    .response-time { color: var(--muted); font-family: monospace; }
    .response-headers {
      padding: 0.5rem 1rem;
      border-bottom: 1px solid var(--border);
      font-size: 0.75rem;
      color: var(--muted);
      font-family: monospace;
      max-height: 100px;
      overflow-y: auto;
    }
    .response-headers div { padding: 0.1rem 0; }
    .response-headers .h-name { color: var(--accent2); }
    .response-body {
      padding: 1rem;
      font-size: 0.85rem;
      font-family: monospace;
      overflow-x: auto;
      white-space: pre-wrap;
      word-break: break-word;
      max-height: 300px;
      overflow-y: auto;
      color: var(--text);
    }
    .response-viewer.empty { display: none; }

    /* Pipeline */
    .pipeline {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 1.25rem;
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
      <p class="tagline">High-performance HTTP engine — Zig owns execution, Lua expresses policy. Try it live below.</p>
      <div class="badges">
        <span class="badge">Zig</span>
        <span class="badge">LuaJIT</span>
        <span class="badge">io_uring</span>
        <span class="badge">libxev</span>
        <span class="badge">picohttpparser</span>
        <span class="badge">eBPF</span>
      </div>
    </div>

    <!-- Live Dashboard -->
    <section>
      <h2><span class="label">Live</span>Dashboard</h2>
      <div class="dashboard">
        <div class="card">
          <div class="card-title">Latency</div>
          <div class="card-value" id="dash-latency">--</div>
          <div class="card-sub" id="dash-latency-sub">Pinging /ping...</div>
          <div class="sparkline" id="dash-sparkline"></div>
        </div>
        <div class="card">
          <div class="card-title">Health</div>
          <div class="card-value" id="dash-health">--</div>
          <div class="card-sub" id="dash-health-sub">Checking /health...</div>
        </div>
        <div class="card">
          <div class="card-title">Stats</div>
          <div class="card-value" id="dash-stats">--</div>
          <div class="card-sub" id="dash-stats-sub">Loading /api/stats...</div>
        </div>
      </div>
    </section>

    <!-- API Playground -->
    <section>
      <h2><span class="label">Interactive</span>API Playground</h2>
      <div class="tabs">
        <button class="tab-btn active" onclick="switchTab('get')">GET Requests</button>
        <button class="tab-btn" onclick="switchTab('params')">Path Params</button>
        <button class="tab-btn" onclick="switchTab('post')">POST & Status</button>
        <button class="tab-btn" onclick="switchTab('headers')">Headers</button>
        <button class="tab-btn" onclick="switchTab('middleware')">Middleware</button>
        <button class="tab-btn" onclick="switchTab('inspect')">Introspection</button>
      </div>

      <!-- GET tab -->
      <div class="tab-panel active" id="tab-get">
        <div class="btn-row">
          <button class="btn" onclick="fire('GET','/ping','resp-get')">GET /ping</button>
          <button class="btn" onclick="fire('GET','/health','resp-get')">GET /health</button>
          <button class="btn" onclick="fire('GET','/users','resp-get')">GET /users</button>
          <button class="btn" onclick="fire('GET','/api/stats','resp-get')">GET /api/stats</button>
        </div>
        <div class="response-viewer empty" id="resp-get"></div>
      </div>

      <!-- Path Params tab -->
      <div class="tab-panel" id="tab-params">
        <div class="input-row">
          <span style="color:var(--muted);font-size:0.85rem">/users/</span>
          <input type="text" id="param-userid" value="42" placeholder="id" style="max-width:100px">
          <button class="btn primary" onclick="fire('GET','/users/'+document.getElementById('param-userid').value,'resp-params')">Send</button>
        </div>
        <div class="input-row">
          <span style="color:var(--muted);font-size:0.85rem">/echo/</span>
          <input type="text" id="param-msg" value="hello-keyway" placeholder="message">
          <button class="btn primary" onclick="fire('GET','/echo/'+document.getElementById('param-msg').value,'resp-params')">Send</button>
        </div>
        <div class="response-viewer empty" id="resp-params"></div>
      </div>

      <!-- POST & Status tab -->
      <div class="tab-panel" id="tab-post">
        <textarea class="body-input" id="post-body">{"name":"Charlie","role":"editor"}</textarea>
        <div class="btn-row">
          <button class="btn primary" onclick="fire('POST','/users','resp-post',{body:document.getElementById('post-body').value,headers:{'Content-Type':'application/json'}})">POST /users</button>
          <button class="btn" onclick="fire('GET','/users/999999','resp-post')">404 Demo</button>
          <button class="btn" onclick="fire('GET','/api/error','resp-post')">500 Demo</button>
        </div>
        <div class="response-viewer empty" id="resp-post"></div>
      </div>

      <!-- Headers tab -->
      <div class="tab-panel" id="tab-headers">
        <div class="input-row">
          <input type="text" id="custom-header-name" value="X-Custom-Header" placeholder="Header name">
          <input type="text" id="custom-header-value" value="keyway-test-value" placeholder="Header value">
        </div>
        <div class="input-row">
          <input type="text" id="custom-header-name2" value="X-Request-Id" placeholder="Header name">
          <input type="text" id="custom-header-value2" value="req-12345" placeholder="Header value">
        </div>
        <div class="btn-row">
          <button class="btn primary" onclick="fireHeaders()">Send to /api/headers</button>
        </div>
        <div class="response-viewer empty" id="resp-headers"></div>
      </div>

      <!-- Middleware tab -->
      <div class="tab-panel" id="tab-middleware">
        <p style="color:var(--muted);font-size:0.85rem;margin-bottom:1rem">
          The middleware chain checks for an Authorization header. Try with/without auth:
        </p>
        <div class="btn-row">
          <button class="btn" onclick="fire('GET','/api/middleware-demo','resp-mw')">No Auth Header</button>
          <button class="btn primary" onclick="fire('GET','/api/middleware-demo','resp-mw',{headers:{'Authorization':'Bearer keyway-demo-token'}})">Correct Bearer</button>
          <button class="btn" onclick="fire('GET','/api/middleware-demo','resp-mw',{headers:{'Authorization':'Bearer wrong-token'}})">Wrong Bearer</button>
        </div>
        <div class="response-viewer empty" id="resp-mw"></div>
      </div>

      <!-- Inspect tab -->
      <div class="tab-panel" id="tab-inspect">
        <div class="btn-row">
          <button class="btn primary" onclick="fire('GET','/api/inspect','resp-inspect')">GET /api/inspect</button>
          <button class="btn" onclick="fire('POST','/api/inspect','resp-inspect',{body:'Hello from the playground!',headers:{'Content-Type':'text/plain'}})">POST /api/inspect</button>
        </div>
        <div class="response-viewer empty" id="resp-inspect"></div>
      </div>
    </section>

    <!-- Code Example -->
    <section>
      <h2><span class="label">Philosophy</span>Lua is a Policy Language</h2>
      <div class="code-block">
        <div class="code-header">handlers.lua</div>
        <pre><code><span class="cm">-- No send(), no write(), no lifecycle calls.</span>
<span class="cm">-- Only state. Lua expresses intent, Zig commits I/O.</span>

keyway.routes = {
    middleware = {
        <span class="kw">function</span>(ctx, next)
            request_count = request_count + <span class="num">1</span>
            next()
        <span class="kw">end</span>,
    },
    [<span class="str">"/users/{id}"</span>] = {
        GET = <span class="kw">function</span>(ctx)
            <span class="kw">local</span> id   = ctx.params.id
            <span class="kw">local</span> role = tonumber(id) % <span class="num">2</span> == <span class="num">0</span>
                         <span class="kw">and</span> <span class="str">"admin"</span> <span class="kw">or</span> <span class="str">"guest"</span>

            ctx.status                    = <span class="num">200</span>
            ctx.headers[<span class="str">"Content-Type"</span>] = <span class="str">"application/json"</span>
            ctx.body = <span class="str">'{"id":'</span> .. id .. <span class="str">',"role":"'</span> .. role .. <span class="str">'"}'</span>
        <span class="kw">end</span>,
    },
}</code></pre>
      </div>
    </section>

    <!-- Architecture -->
    <section>
      <h2><span class="label">Architecture</span>Request Pipeline</h2>
      <div class="pipeline">
        <span class="pipeline-step">RingBuffer</span>
        <span class="pipeline-arrow">&rarr;</span>
        <span class="pipeline-step">picohttpparser</span>
        <span class="pipeline-arrow">&rarr;</span>
        <span class="pipeline-step">Radix Router</span>
        <span class="pipeline-arrow">&rarr;</span>
        <span class="pipeline-step">HttpExchange</span>
        <span class="pipeline-arrow">&rarr;</span>
        <span class="pipeline-step">Lua</span>
        <span class="pipeline-arrow">&rarr;</span>
        <span class="pipeline-step">Response Builder</span>
        <span class="pipeline-arrow">&rarr;</span>
        <span class="pipeline-step">io_uring</span>
        <span class="pipeline-arrow">&rarr;</span>
        <span class="pipeline-step">Kernel</span>
      </div>
      <table class="layers" style="margin-top:1.25rem">
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

    <footer>
      Part of the <a href="https://keystone-gateway.dev" target="_blank">keystone-gateway.dev</a> ecosystem.
    </footer>

  </div>

  <script>
    // ── Core fetch wrapper ──────────────────────────────────────
    async function apiCall(method, path, opts) {
      opts = opts || {};
      var headers = opts.headers || {};
      var t0 = performance.now();
      try {
        var res = await fetch(path, {
          method: method,
          headers: headers,
          body: opts.body || undefined
        });
        var ms = performance.now() - t0;
        var respHeaders = {};
        res.headers.forEach(function(v, k) { respHeaders[k] = v; });
        var body = await res.text();
        return { status: res.status, ms: ms, headers: respHeaders, body: body };
      } catch(e) {
        return { status: 0, ms: performance.now() - t0, headers: {}, body: 'Network error: ' + e.message };
      }
    }

    // ── Response renderer ───────────────────────────────────────
    function renderResponse(targetId, r) {
      var el = document.getElementById(targetId);
      el.classList.remove('empty');
      var sc = r.status >= 500 ? 'status-5xx' : r.status >= 400 ? 'status-4xx' : 'status-2xx';
      var hdrs = '';
      for (var k in r.headers) {
        hdrs += '<div><span class="h-name">' + esc(k) + '</span>: ' + esc(r.headers[k]) + '</div>';
      }
      var body = r.body;
      try { body = JSON.stringify(JSON.parse(body), null, 2); } catch(e) {}
      el.innerHTML =
        '<div class="response-header">' +
          '<span class="status-badge ' + sc + '">' + r.status + '</span>' +
          '<span class="response-time">' + r.ms.toFixed(1) + ' ms</span>' +
        '</div>' +
        (hdrs ? '<div class="response-headers">' + hdrs + '</div>' : '') +
        '<div class="response-body">' + esc(body) + '</div>';
    }

    function esc(s) { var d = document.createElement('div'); d.textContent = s; return d.innerHTML; }

    // ── Fire helper ─────────────────────────────────────────────
    async function fire(method, path, target, opts) {
      renderResponse(target, { status: '...', ms: 0, headers: {}, body: 'Loading...' });
      var r = await apiCall(method, path, opts);
      renderResponse(target, r);
    }

    // ── Headers helper ──────────────────────────────────────────
    async function fireHeaders() {
      var h = {};
      var n1 = document.getElementById('custom-header-name').value;
      var v1 = document.getElementById('custom-header-value').value;
      var n2 = document.getElementById('custom-header-name2').value;
      var v2 = document.getElementById('custom-header-value2').value;
      if (n1) h[n1] = v1;
      if (n2) h[n2] = v2;
      fire('GET', '/api/headers', 'resp-headers', { headers: h });
    }

    // ── Tab switching ───────────────────────────────────────────
    function switchTab(name) {
      document.querySelectorAll('.tab-btn').forEach(function(b) { b.classList.remove('active'); });
      document.querySelectorAll('.tab-panel').forEach(function(p) { p.classList.remove('active'); });
      event.target.classList.add('active');
      document.getElementById('tab-' + name).classList.add('active');
    }

    // ── Dashboard auto-refresh ──────────────────────────────────
    var sparkData = [];
    function startDashboard() {
      // Latency
      setInterval(async function() {
        var r = await apiCall('GET', '/ping');
        document.getElementById('dash-latency').textContent = r.ms.toFixed(1) + ' ms';
        document.getElementById('dash-latency-sub').textContent = r.status === 200 ? 'pong' : 'error';
        sparkData.push(r.ms);
        if (sparkData.length > 20) sparkData.shift();
        var mx = Math.max.apply(null, sparkData) || 1;
        var sp = document.getElementById('dash-sparkline');
        sp.innerHTML = '';
        sparkData.forEach(function(v) {
          var b = document.createElement('div');
          b.className = 'bar';
          b.style.height = Math.max(2, (v / mx) * 24) + 'px';
          sp.appendChild(b);
        });
      }, 2000);

      // Health
      setInterval(async function() {
        var r = await apiCall('GET', '/health');
        try {
          var d = JSON.parse(r.body);
          document.getElementById('dash-health').textContent = d.status || '--';
          document.getElementById('dash-health-sub').textContent = d.engine + ' / ' + d.runtime;
        } catch(e) {
          document.getElementById('dash-health').textContent = 'err';
        }
      }, 5000);

      // Stats
      setInterval(async function() {
        var r = await apiCall('GET', '/api/stats');
        try {
          var d = JSON.parse(r.body);
          document.getElementById('dash-stats').textContent = d.requests + ' reqs';
          document.getElementById('dash-stats-sub').textContent = 'uptime: ' + d.uptime_seconds + 's | ' + d.worker;
        } catch(e) {
          document.getElementById('dash-stats').textContent = 'err';
        }
      }, 3000);

      // Fire initial calls
      apiCall('GET', '/ping').then(function(r) {
        document.getElementById('dash-latency').textContent = r.ms.toFixed(1) + ' ms';
        document.getElementById('dash-latency-sub').textContent = 'pong';
      });
      apiCall('GET', '/health').then(function(r) {
        try {
          var d = JSON.parse(r.body);
          document.getElementById('dash-health').textContent = d.status || '--';
          document.getElementById('dash-health-sub').textContent = d.engine + ' / ' + d.runtime;
        } catch(e) {}
      });
      apiCall('GET', '/api/stats').then(function(r) {
        try {
          var d = JSON.parse(r.body);
          document.getElementById('dash-stats').textContent = d.requests + ' reqs';
          document.getElementById('dash-stats-sub').textContent = 'uptime: ' + d.uptime_seconds + 's | ' + d.worker;
        } catch(e) {}
      });
    }

    startDashboard();
  </script>
</body>
</html>
]=]

-- ── Helper: escape a string for JSON value ──────────────────────────────────
local function json_escape(s)
    if not s then return "" end
    return (s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t'))
end

-- ── Cosocket helpers (loaded before route table) ────────────────────────────
local socket = require("keyway.socket")
require("keyway.ngx_shim")  -- must be before pgmoon (sets ngx global)
local pgmoon = require("pgmoon")

local PG_CONFIG = {
    host = "127.0.0.1", port = 5432,
    database = "keyway_demo", user = "dkremer",
}

local function pg_connect()
    local pg = pgmoon.new(PG_CONFIG)
    local ok, err = pg:connect()
    if not ok then return nil, err end
    return pg
end

-- ── Declarative route table ─────────────────────────────────────────────────

keyway.routes = {
    -- Global middleware: count every request
    middleware = {
        function(ctx, next)
            request_count = request_count + 1
            next()
        end,
    },

    -- Landing page
    ["/"] = {
        GET = function(ctx)
            ctx.status = 200
            ctx.headers["Content-Type"] = "text/html; charset=utf-8"
            ctx.body = landing_page
        end,
    },

    -- Health & status
    ["/ping"] = {
        GET = function(ctx)
            ctx.status = 200
            ctx.body = "pong"
        end,
    },
    ["/health"] = {
        GET = function(ctx)
            ctx.status = 200
            ctx.headers["Content-Type"] = "application/json"
            ctx.body = '{"status":"ok","engine":"keyway","runtime":"luajit"}'
        end,
    },

    -- Users API (PostgreSQL via pgmoon)
    ["/users"] = {
        GET = function(ctx)
            local pg, err = pg_connect()
            if not pg then
                ctx.status = 503
                ctx.headers["Content-Type"] = "application/json"
                ctx.body = '{"error":"db_unavailable","message":"' .. json_escape(err or "unknown") .. '"}'
                return
            end

            local res, query_err = pg:query("SELECT id, name, role FROM users ORDER BY id")
            pg:keepalive()

            if not res then
                ctx.status = 503
                ctx.headers["Content-Type"] = "application/json"
                ctx.body = '{"error":"query_failed","message":"' .. json_escape(query_err or "unknown") .. '"}'
                return
            end

            local parts = {}
            for i = 1, #res do
                local row = res[i]
                parts[#parts + 1] = '{"id":' .. tostring(row.id)
                    .. ',"name":"' .. json_escape(row.name)
                    .. '","role":"' .. json_escape(row.role) .. '"}'
            end

            ctx.status = 200
            ctx.headers["Content-Type"] = "application/json"
            ctx.body = '[' .. table.concat(parts, ',') .. ']'
        end,
        POST = function(ctx)
            local body = ctx.body or ""
            -- Simple JSON field extraction (no full parser needed)
            local name = body:match('"name"%s*:%s*"([^"]*)"')
            local role = body:match('"role"%s*:%s*"([^"]*)"') or "guest"

            if not name or name == "" then
                ctx.status = 400
                ctx.headers["Content-Type"] = "application/json"
                ctx.body = '{"error":"bad_request","message":"name is required"}'
                return
            end

            local pg, err = pg_connect()
            if not pg then
                ctx.status = 503
                ctx.headers["Content-Type"] = "application/json"
                ctx.body = '{"error":"db_unavailable","message":"' .. json_escape(err or "unknown") .. '"}'
                return
            end

            local res, query_err = pg:query(
                "INSERT INTO users (name, role) VALUES ("
                .. pg:escape_literal(name) .. ", "
                .. pg:escape_literal(role)
                .. ") RETURNING id, name, role"
            )
            pg:keepalive()

            if not res or #res == 0 then
                ctx.status = 503
                ctx.headers["Content-Type"] = "application/json"
                ctx.body = '{"error":"insert_failed","message":"' .. json_escape(query_err or "unknown") .. '"}'
                return
            end

            local row = res[1]
            ctx.status = 201
            ctx.headers["Content-Type"] = "application/json"
            ctx.headers["Location"] = "/users/" .. tostring(row.id)
            ctx.body = '{"id":' .. tostring(row.id)
                .. ',"name":"' .. json_escape(row.name)
                .. '","role":"' .. json_escape(row.role) .. '"}'
        end,
        ["/{id}"] = {
            GET = function(ctx)
                local id = ctx.params.id
                local num_id = tonumber(id)
                if not num_id then
                    ctx.status = 400
                    ctx.headers["Content-Type"] = "application/json"
                    ctx.body = '{"error":"bad_request","message":"id must be a number"}'
                    return
                end

                local pg, err = pg_connect()
                if not pg then
                    ctx.status = 503
                    ctx.headers["Content-Type"] = "application/json"
                    ctx.body = '{"error":"db_unavailable","message":"' .. json_escape(err or "unknown") .. '"}'
                    return
                end

                local res, query_err = pg:query(
                    "SELECT id, name, role FROM users WHERE id = "
                    .. pg:escape_literal(tostring(num_id))
                )
                pg:keepalive()

                if not res then
                    ctx.status = 503
                    ctx.headers["Content-Type"] = "application/json"
                    ctx.body = '{"error":"query_failed","message":"' .. json_escape(query_err or "unknown") .. '"}'
                    return
                end

                if #res == 0 then
                    ctx.status = 404
                    ctx.headers["Content-Type"] = "application/json"
                    ctx.body = '{"error":"not_found","message":"user ' .. tostring(num_id) .. ' not found"}'
                    return
                end

                local row = res[1]
                ctx.status = 200
                ctx.headers["Content-Type"] = "application/json"
                ctx.body = '{"id":' .. tostring(row.id)
                    .. ',"name":"' .. json_escape(row.name)
                    .. '","role":"' .. json_escape(row.role) .. '"}'
            end,
        },
    },

    -- Echo & debug
    ["/echo"] = {
        ["/{message}"] = {
            GET = function(ctx)
                ctx.status = 200
                ctx.body = ctx.params.message
            end,
        },
    },
    ["/debug"] = {
        GET = function(ctx)
            local method      = ctx.method
            local path        = ctx.path
            local content_type = ctx.headers["Content-Type"] or ""
            local accept      = ctx.headers["Accept"] or ""
            ctx.status = 200
            ctx.headers["Content-Type"] = "application/json"
            ctx.body = '{"method":"' .. method .. '","path":"' .. path
                   .. '","headers":{"Content-Type":"' .. content_type
                   .. '","Accept":"' .. accept .. '"}}'
        end,
    },

    -- ── New API routes ──────────────────────────────────────────────────────

    ["/api"] = {
        -- Stats: per-worker request count and uptime
        ["/stats"] = {
            GET = function(ctx)
                local uptime = os.time() - start_time
                ctx.status = 200
                ctx.headers["Content-Type"] = "application/json"
                ctx.body = '{"requests":' .. request_count
                       .. ',"uptime_seconds":' .. uptime
                       .. ',"worker":"per-core-isolated"}'
            end,
        },

        -- Headers echo: check known header names, echo back what was found
        ["/headers"] = {
            GET = function(ctx)
                local known = {
                    "Host", "User-Agent", "Accept", "Content-Type",
                    "Authorization", "X-Custom-Header", "X-Request-Id",
                    "X-Forwarded-For", "Origin", "Referer"
                }
                local parts = {}
                for _, name in ipairs(known) do
                    local val = ctx.headers[name]
                    if val then
                        parts[#parts + 1] = '"' .. json_escape(name) .. '":"' .. json_escape(val) .. '"'
                    end
                end
                ctx.status = 200
                ctx.headers["Content-Type"] = "application/json"
                ctx.headers["X-Powered-By"] = "keyway/zig+luajit"
                ctx.headers["X-Worker"] = "per-core-isolated"
                ctx.body = '{"received_headers":{' .. table.concat(parts, ",") .. '}}'
            end,
        },

        -- Middleware demo: timing + auth check
        ["/middleware-demo"] = {
            middleware = {
                -- Timing middleware (wraps entire chain)
                function(ctx, next)
                    local t0 = os.clock()
                    next()
                    local elapsed = string.format("%.3fms", (os.clock() - t0) * 1000)
                    -- Append timing info to the trace the handler already built
                    local trace = ctx.headers["X-Middleware-Trace"] or "unknown"
                    ctx.headers["X-Middleware-Trace"] = trace .. " > timing:" .. elapsed
                end,
                -- Auth middleware (gate before handler)
                function(ctx, next)
                    local auth = ctx.headers["Authorization"]
                    if auth then
                        if auth ~= "Bearer keyway-demo-token" then
                            ctx.status = 401
                            ctx.headers["Content-Type"] = "application/json"
                            ctx.headers["X-Middleware-Trace"] = "timing > auth-rejected (short-circuit)"
                            ctx.body = '{"error":"unauthorized","message":"Invalid bearer token. Expected: Bearer keyway-demo-token","middleware_chain":"timing > auth-rejected (short-circuit)"}'
                            return  -- short-circuit: don't call next()
                        end
                    end
                    next()
                end,
            },
            GET = function(ctx)
                local auth = ctx.headers["Authorization"]
                local authed = auth and auth == "Bearer keyway-demo-token"
                local auth_step = authed and "auth-ok" or "auth-pass"
                local trace = "timing > " .. auth_step .. " > handler"
                ctx.status = 200
                ctx.headers["Content-Type"] = "application/json"
                ctx.headers["X-Middleware-Trace"] = trace
                ctx.body = '{"message":"Middleware demo complete",'
                       .. '"authenticated":' .. (authed and 'true' or 'false')
                       .. ',"middleware_chain":"' .. json_escape(trace) .. '"}'
            end,
        },

        -- Request introspection
        ["/inspect"] = {
            GET = function(ctx)
                local method = ctx.method
                local path = ctx.path
                local host = ctx.headers["Host"] or ""
                local ua = ctx.headers["User-Agent"] or ""
                local accept = ctx.headers["Accept"] or ""
                local ct = ctx.headers["Content-Type"] or ""
                ctx.status = 200
                ctx.headers["Content-Type"] = "application/json"
                ctx.body = '{"method":"' .. json_escape(method)
                       .. '","path":"' .. json_escape(path)
                       .. '","host":"' .. json_escape(host)
                       .. '","user_agent":"' .. json_escape(ua)
                       .. '","accept":"' .. json_escape(accept)
                       .. '","content_type":"' .. json_escape(ct)
                       .. '","body_length":0'
                       .. ',"body_preview":""}'
            end,
            POST = function(ctx)
                local method = ctx.method
                local path = ctx.path
                local host = ctx.headers["Host"] or ""
                local ua = ctx.headers["User-Agent"] or ""
                local accept = ctx.headers["Accept"] or ""
                local ct = ctx.headers["Content-Type"] or ""
                local body = ctx.body or ""
                local blen = #body
                local preview = body:sub(1, 200)
                ctx.status = 200
                ctx.headers["Content-Type"] = "application/json"
                ctx.body = '{"method":"' .. json_escape(method)
                       .. '","path":"' .. json_escape(path)
                       .. '","host":"' .. json_escape(host)
                       .. '","user_agent":"' .. json_escape(ua)
                       .. '","accept":"' .. json_escape(accept)
                       .. '","content_type":"' .. json_escape(ct)
                       .. '","body_length":' .. blen
                       .. ',"body_preview":"' .. json_escape(preview) .. '"}'
            end,
        },

        -- Intentional 500 error
        ["/error"] = {
            GET = function(ctx)
                ctx.status = 500
                ctx.headers["Content-Type"] = "application/json"
                ctx.body = '{"error":"intentional_error","message":"This is a deliberate 500 response for testing error handling in the playground."}'
            end,
        },
    },

    -- Cosocket: Redis via socket module (pooled)
    ["/redis-socket"] = {
        GET = function(ctx)
            local sock = socket.tcp()
            local ok, err = sock:connect("127.0.0.1", 6379)
            if not ok then ctx.status = 502; ctx.body = err; return end

            sock:send("*1\r\n$4\r\nPING\r\n")
            local line = sock:receive("*l")
            local reused = sock:getreusedtimes()
            sock:setkeepalive()  -- zero config

            ctx.status = 200
            ctx.body = (line or "no response") .. " (reused: " .. tostring(reused) .. ")"
        end,
    },

    -- Cosocket: Redis pooled (thin, no wrapper overhead)
    ["/redis-pool-raw"] = {
        GET = function(ctx)
            local pool_name = "127.0.0.1:6379"
            local fd, reuse = __keyway_pool_connect(pool_name, "127.0.0.1", 6379)
            if not fd then
                ctx.status = 502
                ctx.body = "connection failed"
                return
            end
            __keyway_io_send(fd, "*1\r\n$4\r\nPING\r\n")
            local data = __keyway_io_recv(fd, 4096)
            __keyway_pool_setkeepalive(fd, pool_name, 0, 0, reuse)
            ctx.status = 200
            ctx.body = (data or "no response") .. " (reused: " .. tostring(reuse) .. ")"
        end,
    },

    -- Cosocket: Redis ping (raw, no pooling)
    ["/redis-ping"] = {
        GET = function(ctx)
            local fd = __keyway_io_connect("127.0.0.1", 6379)
            if not fd then
                ctx.status = 502
                ctx.body = "connection failed"
                return
            end
            __keyway_io_send(fd, "*1\r\n$4\r\nPING\r\n")
            local data = __keyway_io_recv(fd, 4096)
            __keyway_io_close(fd)
            ctx.status = 200
            ctx.body = data or "no response"
        end,
    },
}
