class X{data=new Map;listeners=new Map;get(e){return this.data.get(e)}set(e,t){this.data.set(e,t);let i=this.listeners.get(e);if(i)i.forEach((a)=>a(t))}update(e,t){this.set(e,t(this.get(e)))}on(e,t){let i=this.listeners.get(e);if(!i)i=new Set,this.listeners.set(e,i);return i.add(t),()=>i.delete(t)}}var v=new X;var N=[],Y,O=null;function w(e,t,i,a){N.push({path:e,label:t,icon:i,mount:a})}function A(){return N}function K(e){location.hash=e}function $(e,t){for(let[i,a]of Object.entries(t))v.set(i,a);K(e)}function B(e){O=e,window.addEventListener("hashchange",()=>Z()),Z()}function Z(){if(!O)return;let e=location.hash.slice(1)||N[0]?.path||"/traffic",t=N.find((i)=>i.path===e)||N[0];if(!t)return;if(Y)Y();O.innerHTML="",Y=t.mount(O),document.querySelectorAll("[data-nav]").forEach((i)=>{let a=i;if(a.dataset.nav===t.path)a.classList.add("active");else a.classList.remove("active")})}var ce="";async function g(e,t={}){let r=await fetch(`${ce}${e}`,{headers:{"Content-Type":"application/json",...t.headers},...t});if(!r.ok)throw new Error(r.status);return r.json()}var _=null,de=null;function U(){if(_)return;v.set("sse_status","connecting"),_=new EventSource("/__keyway/events"),_.onopen=()=>{v.set("sse_status","connected")},_.addEventListener("message",(e)=>{try{let t=JSON.parse(e.data);if(t.method&&t.path&&t.status!==void 0){let i={method:t.method,path:t.path,status:t.status,latency:t.latency||"",latency_us:t.latency_us||0,worker_id:t.worker_id||"",content_type:t.content_type||"",header_count:t.header_count||0,scripts:t.scripts||void 0,hook_id:t.hook_id||void 0,ts:Date.now()};v.update("traffic",(a)=>{let r=[i,...a||[]];return r.length>500?r.slice(0,500):r})}else v.set("sse_event",t)}catch{}}),_.onerror=()=>{v.set("sse_status","disconnected"),_?.close(),_=null,de=setTimeout(U,3000)}}var L=null,ue=null;function C(){if(L)return;v.set("ws_status","connecting");let e=location.protocol==="https:"?"wss:":"ws:";L=new WebSocket(`${e}//${location.host}/__keyway/ws`),L.onopen=()=>{v.set("ws_status","connected")},L.onmessage=(t)=>{try{let i=JSON.parse(t.data);v.update("ws_messages",(a)=>{let r=[...a||[],{...i,_ts:Date.now()}];return r.length>200?r.slice(-200):r})}catch{}},L.onclose=()=>{v.set("ws_status","disconnected"),L=null,ue=setTimeout(C,3000)},L.onerror=()=>{L?.close()}}function R(e){if(L?.readyState===WebSocket.OPEN)L.send(JSON.stringify(e))}function D(e){return`<span class="inline-block w-2 h-2 rounded-full ${e==="connected"?"bg-success":e==="connecting"?"bg-warning":"bg-error"}"></span>`}function I(){let e=document.getElementById("app");e.innerHTML="";let t=document.createElement("aside");t.className="w-48 bg-base-200 border-r border-base-300 flex flex-col shrink-0";let i=document.createElement("div");i.className="px-4 py-3 border-b border-base-300",i.innerHTML='<span class="text-primary font-bold text-sm tracking-wide">KEYWAY</span>',t.appendChild(i);let a=document.createElement("nav");a.className="flex-1 py-2";for(let x of A()){let n=document.createElement("a");n.dataset.nav=x.path,n.className="flex items-center gap-2 px-4 py-1.5 text-xs cursor-pointer hover:bg-base-300 text-base-content/70 hover:text-base-content transition-colors [&.active]:text-primary [&.active]:bg-base-300/50",n.innerHTML=`<span class="opacity-60">${x.icon}</span> ${x.label}`,n.addEventListener("click",()=>K(x.path)),a.appendChild(n)}t.appendChild(a);let u=document.createElement("div");u.id="conn-status",u.className="px-4 py-2 border-t border-base-300 text-[10px] text-base-content/50 space-y-1",t.appendChild(u);function r(){let x=v.get("sse_status")||"disconnected",n=v.get("ws_status")||"disconnected";u.innerHTML=`
      <div class="flex items-center gap-1.5">${D(x)} SSE ${x}</div>
      <div class="flex items-center gap-1.5">${D(n)} WS ${n}</div>
    `}let m=v.on("sse_status",r),f=v.on("ws_status",r);r();let l=document.createElement("main");l.className="flex-1 overflow-auto";let c=document.createElement("div");return c.className="h-full",l.appendChild(c),e.className="flex h-screen bg-base-100 text-base-content text-xs",e.appendChild(t),e.appendChild(l),{content:c,cleanup:()=>{m(),f()}}}function P(e){return`<span class="method-${e} font-semibold">${e}</span>`}function j(e){let t="text-base-content/50";if(e>=200&&e<300)t="status-2xx";else if(e>=300&&e<400)t="status-3xx";else if(e>=400&&e<500)t="status-4xx";else if(e>=500)t="status-5xx";return`<span class="${t}">${e}</span>`}function H(e){return e.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")}function le(e){let t=new Date(e);return t.toLocaleTimeString("en-US",{hour12:!1,hour:"2-digit",minute:"2-digit",second:"2-digit"})+"."+String(t.getMilliseconds()).padStart(3,"0")}var be=500;function F(e){e.innerHTML=`
    <div class="flex flex-col h-full">
      <div class="flex items-center gap-3 px-4 py-2 border-b border-base-300 bg-base-200/50">
        <h2 class="text-sm font-semibold text-base-content/80">Traffic</h2>
        <div class="flex-1"></div>
        <input id="traffic-filter" type="text" placeholder="Filter path..."
          class="input input-xs input-bordered bg-base-100 w-48 text-[11px]" />
        <button id="traffic-pause" class="btn btn-xs btn-ghost text-base-content/50">Pause</button>
        <button id="traffic-clear" class="btn btn-xs btn-ghost text-base-content/50">Clear</button>
      </div>
      <div id="traffic-list" class="flex-1 overflow-y-auto"></div>
    </div>
  `;let t=e.querySelector("#traffic-list"),i=e.querySelector("#traffic-filter"),a=e.querySelector("#traffic-pause"),u=e.querySelector("#traffic-clear"),r=!1,m="",f=null;function l(s){if(s>=500)return"text-error";if(s>=400)return"text-warning";if(s>=300)return"text-info";if(s>=200)return"text-success";return"text-base-content/50"}function c(s,d){let h=f===d,T=s.scripts?.length||0,k=[T>0?`<span class="badge badge-xs badge-primary/30 text-[9px]">${T} script${T>1?"s":""}</span>`:"",s.hook_id?`<span class="badge badge-xs badge-info/30 text-[9px] hook-badge" data-hook="${H(s.hook_id)}">hook</span>`:""].filter(Boolean).join("");return`
      <div class="traffic-row border-b border-base-300/30 cursor-pointer hover:bg-base-300/30 ${h?"bg-base-300/20":""}" data-idx="${d}">
        <div class="flex items-center gap-2 px-4 py-1.5 text-[11px]">
          <span class="w-[60px] shrink-0">${P(s.method)}</span>
          <span class="flex-1 text-base-content/80 truncate">${H(s.path)}</span>
          ${k?`<span class="flex gap-1 shrink-0">${k}</span>`:""}
          <span class="w-[50px] shrink-0 text-right">${j(s.status)}</span>
          <span class="w-[70px] shrink-0 text-right text-base-content/50">${s.latency}</span>
          <span class="w-[40px] shrink-0 text-right text-base-content/30">${s.worker_id}</span>
        </div>
        ${h?x(s):""}
      </div>
    `}function x(s){let d=s.scripts&&s.scripts.length>0?`<div><span class="text-base-content/40">Scripts</span> <span class="ml-2">${s.scripts.map((T)=>`<a class="text-primary cursor-pointer hover:underline script-link" data-script-id="${H(T.id)}">${H(T.name)}</a>`).join(", ")}</span></div>`:"",h=s.hook_id?`<div><span class="text-base-content/40">Hook</span> <a class="text-info cursor-pointer hover:underline ml-2 hook-link" data-hook-id="${H(s.hook_id)}">/h/${H(s.hook_id)}</a></div>`:"";return`
      <div class="px-4 py-2 bg-base-200/50 border-t border-base-300/30 text-[10px] space-y-1">
        <div class="grid grid-cols-2 gap-x-6 gap-y-1">
          <div><span class="text-base-content/40">Timestamp</span> <span class="text-base-content/70 ml-2">${le(s.ts)}</span></div>
          <div><span class="text-base-content/40">Worker</span> <span class="text-base-content/70 ml-2">${s.worker_id}</span></div>
          <div><span class="text-base-content/40">Path</span> <span class="text-base-content/70 ml-2">${H(s.path)}</span></div>
          <div><span class="text-base-content/40">Status</span> <span class="${l(s.status)} ml-2">${s.status}</span></div>
          <div><span class="text-base-content/40">Latency</span> <span class="text-base-content/70 ml-2">${s.latency}${s.latency_us?` (${s.latency_us}us)`:""}</span></div>
          <div><span class="text-base-content/40">Content-Type</span> <span class="text-base-content/70 ml-2">${H(s.content_type||"-")}</span></div>
          <div><span class="text-base-content/40">Method</span> <span class="text-base-content/70 ml-2">${s.method}</span></div>
          <div><span class="text-base-content/40">Req Headers</span> <span class="text-base-content/70 ml-2">${s.header_count||"-"}</span></div>
          ${d}
          ${h}
        </div>
      </div>
    `}function n(s){t.innerHTML=s.slice(0,be).map((d,h)=>c(d,h)).join("")}function o(){let s=v.get("traffic")||[];return m?s.filter((d)=>d.path.includes(m)):s}t.addEventListener("click",(s)=>{let d=s.target,h=d.closest(".script-link");if(h){s.stopPropagation(),$("/scripts",{navigate_to_script:h.dataset.scriptId});return}let T=d.closest(".hook-link");if(T){s.stopPropagation(),$("/hooks",{navigate_to_hook:T.dataset.hookId});return}let k=d.closest(".hook-badge");if(k){s.stopPropagation(),$("/hooks",{navigate_to_hook:k.dataset.hook});return}let G=d.closest(".traffic-row");if(!G)return;let W=parseInt(G.dataset.idx||"");if(isNaN(W))return;f=f===W?null:W,n(o())});let p=v.get("navigate_to_traffic_filter");if(p)m=p,i.value=p,v.set("navigate_to_traffic_filter",void 0);n(o());let b=v.on("traffic",()=>{if(r)return;f=null,n(o())});let _ft;return i.addEventListener("input",()=>{clearTimeout(_ft),_ft=setTimeout(()=>{m=i.value,f=null,n(o())},200)}),a.addEventListener("click",()=>{if(r=!r,a.textContent=r?"Resume":"Pause",a.classList.toggle("text-warning",r),!r)f=null,n(o())}),u.addEventListener("click",()=>{v.set("traffic",[]),f=null,t.innerHTML=""}),()=>b()}function ee(e,t={}){e.innerHTML="",e.className+=" flex relative bg-base-100 border border-base-300 rounded";let i=document.createElement("div");i.className="py-2 px-2 text-right text-base-content/20 select-none leading-[1.5] text-[11px] min-w-[3rem] border-r border-base-300 overflow-hidden",e.appendChild(i);let a=document.createElement("textarea");if(a.className="flex-1 bg-transparent text-base-content p-2 outline-none resize-none leading-[1.5] text-[11px] font-mono",a.spellcheck=!1,a.value=t.value||"",a.placeholder=t.placeholder||"-- Lua script...",t.readonly)a.readOnly=!0;e.appendChild(a);function u(){let r=a.value.split(`
`).length;i.innerHTML=Array.from({length:r},(m,f)=>f+1).join("<br>")}return a.addEventListener("input",()=>{u(),t.onChange?.(a.value)}),a.addEventListener("scroll",()=>{i.scrollTop=a.scrollTop}),a.addEventListener("keydown",(r)=>{if(r.key==="Tab"){r.preventDefault();let{selectionStart:m,selectionEnd:f}=a;a.value=a.value.substring(0,m)+"  "+a.value.substring(f),a.selectionStart=a.selectionEnd=m+2,t.onChange?.(a.value),u()}}),u(),{getValue:()=>a.value,setValue:(r)=>{a.value=r,u()}}}var te={rate_limiter:{name:"Rate Limiter",type:"middleware",pattern:"^/api/",code:`-- Rate limiter: 100 req/min per path
local counters = {}
local window = 60

return function(ctx, next)
  local key = ctx.path
  local now = os.time()
  local entry = counters[key]

  if not entry or (now - entry.ts) > window then
    counters[key] = { ts = now, count = 1 }
    next()
    return
  end

  entry.count = entry.count + 1
  if entry.count > 100 then
    ctx.status = 429
    ctx.headers["Content-Type"] = "application/json"
    ctx.body = '{"error":"rate limit exceeded"}'
    return
  end

  next()
end`},cors:{name:"CORS Headers",type:"middleware",pattern:"^/api/",code:`-- CORS middleware
return function(ctx, next)
  ctx.headers["Access-Control-Allow-Origin"] = "*"
  ctx.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
  ctx.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"

  if ctx.method == "OPTIONS" then
    ctx.status = 204
    return
  end

  next()
end`},auth_check:{name:"Auth Check",type:"middleware",pattern:"^/api/",code:`-- Bearer token auth check
local TOKEN = "changeme"

return function(ctx, next)
  local auth = nil
  for _, h in ipairs(ctx.request_headers) do
    if h[1]:lower() == "authorization" then
      auth = h[2]
      break
    end
  end

  if not auth or auth ~= "Bearer " .. TOKEN then
    ctx.status = 401
    ctx.headers["Content-Type"] = "application/json"
    ctx.body = '{"error":"unauthorized"}'
    return
  end

  next()
end`},upstream_proxy:{name:"Upstream Proxy",type:"handler",pattern:"/api/proxy",code:`-- Proxy requests to upstream (socket, dns are sandbox globals)
return function(ctx)
  local ip = dns.resolve_host("httpbin.org")
  if not ip then
    ctx.status = 502
    ctx.body = '{"error":"dns failed"}'
    return
  end

  local tcp = socket.tcp()
  tcp:settimeout(5000)
  local ok = tcp:connect(ip, 80)
  if not ok then
    ctx.status = 502
    ctx.body = '{"error":"connect failed"}'
    return
  end

  tcp:send("GET /get HTTP/1.1\\r\\nHost: httpbin.org\\r\\nConnection: close\\r\\n\\r\\n")
  tcp:receive("*l") -- status
  while true do
    local line = tcp:receive("*l")
    if not line or line == "" then break end
  end
  local body = tcp:receive("*a") or ""
  tcp:close()

  ctx.status = 200
  ctx.headers["Content-Type"] = "application/json"
  ctx.body = body
end`},canary_router:{name:"Canary Router",type:"middleware",pattern:"^/api/",code:`-- Canary: route 10% of traffic to canary upstream
return function(ctx, next)
  if math.random() < 0.10 then
    ctx.headers["X-Canary"] = "true"
    -- Route to canary upstream here
    -- e.g., modify ctx or use cosocket to proxy
  end
  next()
end`},request_logger:{name:"Request Logger",type:"middleware",pattern:".",code:`-- Log all requests with timing (response is a sandbox global)
return function(ctx, next)
  local t0 = response.now_us()
  next()
  local elapsed = math.floor(response.now_us() - t0)
  -- Log is available via SSE traffic stream
  ctx.headers["X-Request-Time-Us"] = tostring(elapsed)
end`}},y=null,z=null;async function M(){try{let e=await g("/__keyway/api/scripts");return v.set("scripts",e.scripts),e.scripts}catch{return[]}}function Q(e,t,i){if(e.innerHTML="",t.length===0){e.innerHTML='<div class="p-4 text-base-content/30 text-center">No scripts</div>';return}for(let a of t){let u=document.createElement("div");u.className=`px-3 py-2 cursor-pointer hover:bg-base-300 border-b border-base-300/50 ${y?.id===a.id?"bg-base-300/50 border-l-2 border-l-primary":""}`,u.innerHTML=`
      <div class="flex items-center gap-2">
        <span class="font-medium text-base-content/80">${J(a.name)}</span>
        <span class="ml-auto badge badge-xs ${a.enabled?"badge-success":"badge-ghost"}">${a.enabled?"on":"off"}</span>
      </div>
      <div class="text-[10px] text-base-content/30 mt-0.5">
        ${a.type} · ${J(a.pattern)} · ${a.metrics.calls} calls
      </div>
    `,u.addEventListener("click",()=>i(a)),e.appendChild(u)}}function J(e){return e.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")}function ne(e){e.innerHTML=`
    <div class="flex flex-col h-full">
      <div class="flex items-center gap-3 px-4 py-2 border-b border-base-300 bg-base-200/50">
        <h2 class="text-sm font-semibold text-base-content/80">Scripts</h2>
        <div class="flex-1"></div>
        <select id="script-template" class="select select-xs select-bordered bg-base-100 text-[11px]">
          <option value="">Template...</option>
          ${Object.entries(te).map(([n,o])=>`<option value="${n}">${o.name}</option>`).join("")}
        </select>
        <button id="script-new" class="btn btn-xs btn-primary">New</button>
      </div>
      <div class="flex flex-1 overflow-hidden">
        <div id="script-list" class="w-56 border-r border-base-300 overflow-y-auto shrink-0"></div>
        <div class="flex-1 flex flex-col overflow-hidden">
          <div id="script-meta" class="px-4 py-2 border-b border-base-300 bg-base-200/30"></div>
          <div id="script-editor" class="flex-1 overflow-hidden"></div>
          <div id="script-actions" class="flex items-center gap-2 px-4 py-2 border-t border-base-300 bg-base-200/30"></div>
        </div>
      </div>
    </div>
  `;let t=e.querySelector("#script-list"),i=e.querySelector("#script-meta"),a=e.querySelector("#script-editor"),u=e.querySelector("#script-actions"),r=e.querySelector("#script-new"),m=e.querySelector("#script-template");function f(n){y=n,l(n),c(n),x(n),M().then((o)=>Q(t,o,f))}function l(n){i.innerHTML=`
      <div class="flex items-center gap-3 flex-wrap">
        <input id="meta-name" class="input input-xs input-bordered bg-base-100 w-40 text-[11px]" value="${J(n.name)}" />
        <select id="meta-type" class="select select-xs select-bordered bg-base-100 text-[11px]">
          <option value="middleware" ${n.type==="middleware"?"selected":""}>Middleware</option>
          <option value="handler" ${n.type==="handler"?"selected":""}>Handler</option>
        </select>
        <input id="meta-pattern" class="input input-xs input-bordered bg-base-100 w-40 text-[11px]" placeholder="Pattern/Path" value="${J(n.pattern)}" />
        <input id="meta-priority" class="input input-xs input-bordered bg-base-100 w-16 text-[11px]" type="number" placeholder="Pri" value="${n.priority}" />
        <div class="ml-auto flex items-center gap-2 text-[10px] text-base-content/40">
          <span>${n.metrics.calls} calls</span>
          <span>${n.metrics.errors} errors</span>
        </div>
      </div>
    `}function c(n){a.innerHTML="",z=ee(a,{value:n.code})}function x(n){u.innerHTML=`
      <button id="action-save" class="btn btn-xs btn-primary">Deploy</button>
      <button id="action-toggle" class="btn btn-xs ${n.enabled?"btn-warning":"btn-success"}">${n.enabled?"Disable":"Enable"}</button>
      <button id="action-test" class="btn btn-xs btn-ghost">Test</button>
      <div class="flex-1"></div>
      <button id="action-delete" class="btn btn-xs btn-error btn-ghost">Delete</button>
    `,u.querySelector("#action-save").addEventListener("click",async()=>{if(!y)return;let o=i.querySelector("#meta-name").value,p=i.querySelector("#meta-type").value,b=i.querySelector("#meta-pattern").value,s=parseInt(i.querySelector("#meta-priority").value)||0,d=z?.getValue()||"";await g(`/__keyway/api/scripts/${y.id}`,{method:"PUT",body:JSON.stringify({name:o,type:p,pattern:b,priority:s,code:d})});let T=(await M()).find((k)=>k.id===y.id);if(T)f(T)}),u.querySelector("#action-toggle").addEventListener("click",async()=>{if(!y)return;await g(`/__keyway/api/scripts/${y.id}/toggle`,{method:"POST"});let p=(await M()).find((b)=>b.id===y.id);if(p)f(p)}),u.querySelector("#action-test").addEventListener("click",async()=>{if(!y)return;let o=await g(`/__keyway/api/scripts/${y.id}/test`,{method:"POST",body:JSON.stringify({method:"GET",path:y.pattern,headers:{},body:""})});alert(JSON.stringify(o,null,2))}),u.querySelector("#action-delete").addEventListener("click",async()=>{if(!y)return;if(!confirm(`Delete "${y.name}"?`))return;await g(`/__keyway/api/scripts/${y.id}`,{method:"DELETE"}),y=null,a.innerHTML='<div class="flex items-center justify-center h-full text-base-content/20">Select or create a script</div>',i.innerHTML="",u.innerHTML="";let o=await M();Q(t,o,f)})}return r.addEventListener("click",async()=>{let n=await g("/__keyway/api/scripts",{method:"POST",body:JSON.stringify({name:"New Script",type:"middleware",pattern:".",priority:0,code:`-- New script
return function(ctx, next)
  next()
end`})}),o=await M();f(n.script)}),m.addEventListener("change",async()=>{let n=m.value;if(!n)return;let o=te[n],p=await g("/__keyway/api/scripts",{method:"POST",body:JSON.stringify({name:o.name,type:o.type,pattern:o.pattern,priority:0,code:o.code})});m.value="";let b=await M();f(p.script)}),a.innerHTML='<div class="flex items-center justify-center h-full text-base-content/20">Select or create a script</div>',M().then((n)=>{Q(t,n,f);let o=v.get("navigate_to_script");if(o){v.set("navigate_to_script",void 0);let p=n.find((b)=>b.id===o);if(p)f(p)}}),()=>{y=null,z=null}}var pe=new Set(["strict-transport-security","content-security-policy","x-content-type-options","x-frame-options","x-xss-protection","referrer-policy","permissions-policy"]),ve=new Set(["cache-control","etag","last-modified","expires","age","vary"]);function me(e){let t=e.toLowerCase();if(pe.has(t))return"text-success";if(ve.has(t))return"text-info";return"text-base-content/50"}function oe(e){if(e>=200&&e<300)return"status-2xx";if(e>=300&&e<400)return"status-3xx";if(e>=400&&e<500)return"status-4xx";if(e>=500)return"status-5xx";return""}function q(e){return e.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")}function se(e){e.innerHTML=`
    <div class="flex flex-col h-full">
      <div class="flex items-center gap-3 px-4 py-2 border-b border-base-300 bg-base-200/50">
        <h2 class="text-sm font-semibold text-base-content/80">HTTP Probe</h2>
      </div>
      <div class="p-4 space-y-4 overflow-y-auto flex-1">
        <div class="flex gap-2">
          <input id="probe-url" type="text" placeholder="https://example.com"
            class="input input-sm input-bordered bg-base-100 flex-1 text-[11px]" />
          <button id="probe-send" class="btn btn-sm btn-primary">Probe</button>
        </div>
        <div id="probe-result"></div>
        <div id="probe-history" class="space-y-2"></div>
      </div>
    </div>
  `;let t=e.querySelector("#probe-url"),i=e.querySelector("#probe-send"),a=e.querySelector("#probe-result"),u=e.querySelector("#probe-history"),r=[];async function m(){let l=t.value.trim();if(!l)return;i.disabled=!0,i.textContent="...",a.innerHTML='<div class="text-base-content/30">Probing...</div>';try{let c=await g("/__keyway/api/probe",{method:"POST",body:JSON.stringify({url:l})});if(c.error){a.innerHTML=`<div class="text-error">${q(c.error)}</div>`;return}if(r.unshift({url:l,status:c.status,timing_ms:c.timing_ms}),r.length>10)r.pop();f();let x=c.headers.map(([n,o])=>`<tr><td class="${me(n)} whitespace-nowrap pr-3">${q(n)}</td><td class="text-base-content/70 break-all">${q(o)}</td></tr>`).join("");a.innerHTML=`
        <div class="space-y-3">
          <div class="flex items-center gap-3">
            <span class="${oe(c.status)} text-lg font-bold">${c.status}</span>
            <span class="text-base-content/40">${c.timing_ms}ms</span>
          </div>
          <div class="overflow-x-auto">
            <table class="table table-xs"><tbody>${x}</tbody></table>
          </div>
          ${c.body_preview?`<div class="bg-base-200 p-2 rounded text-[10px] text-base-content/60 max-h-40 overflow-auto whitespace-pre-wrap">${q(c.body_preview)}</div>`:""}
        </div>
      `}catch(c){a.innerHTML=`<div class="text-error">Probe failed: ${c}</div>`}finally{i.disabled=!1,i.textContent="Probe"}}function f(){u.innerHTML=r.length?'<div class="text-[10px] text-base-content/30 mb-1">History</div>'+r.map((l)=>`<div class="flex items-center gap-2 text-[10px] text-base-content/40 cursor-pointer hover:text-base-content/60" data-url="${q(l.url)}">
                <span class="${oe(l.status)}">${l.status}</span>
                <span class="truncate flex-1">${q(l.url)}</span>
                <span>${l.timing_ms}ms</span>
              </div>`).join(""):"",u.querySelectorAll("[data-url]").forEach((l)=>{l.addEventListener("click",()=>{t.value=l.dataset.url||""})})}return i.addEventListener("click",m),t.addEventListener("keydown",(l)=>{if(l.key==="Enter")m()}),()=>{}}function S(e){return e.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")}function ae(e){e.innerHTML=`
    <div class="flex flex-col h-full">
      <div class="flex items-center gap-3 px-4 py-2 border-b border-base-300 bg-base-200/50">
        <h2 class="text-sm font-semibold text-base-content/80">Webhooks</h2>
        <div class="flex-1"></div>
        <button id="hooks-create" class="btn btn-xs btn-primary">New Endpoint</button>
      </div>
      <div class="flex flex-1 overflow-hidden">
        <div id="hooks-list" class="w-56 border-r border-base-300 overflow-y-auto shrink-0"></div>
        <div id="hooks-detail" class="flex-1 overflow-y-auto p-4">
          <div class="flex items-center justify-center h-full text-base-content/20">Select or create an endpoint</div>
        </div>
      </div>
    </div>
  `;let t=e.querySelector("#hooks-list"),i=e.querySelector("#hooks-detail"),a=e.querySelector("#hooks-create"),u=null,r=null;async function m(){try{let n=await g("/__keyway/api/hooks");f(n.hooks)}catch{}}function f(n){if(t.innerHTML="",n.length===0){t.innerHTML='<div class="p-4 text-base-content/30 text-center">No endpoints</div>';return}for(let o of n){let p=document.createElement("div");p.className=`px-3 py-2 cursor-pointer hover:bg-base-300 border-b border-base-300/50 ${u===o.id?"bg-base-300/50 border-l-2 border-l-primary":""}`,p.innerHTML=`
        <div class="font-medium text-base-content/80 text-[11px]">/h/${S(o.id)}</div>
        <div class="text-[10px] text-base-content/30">${o.request_count} captured</div>
      `,p.addEventListener("click",()=>l(o.id)),t.appendChild(p)}}async function l(n){if(u=n,r)r.close();i.innerHTML=`
      <div class="space-y-3">
        <div class="flex items-center gap-2">
          <code class="text-primary text-[11px]">${location.origin}/h/${S(n)}</code>
          <button id="hook-copy" class="btn btn-xs btn-ghost">Copy</button>
          <div class="flex-1"></div>
          <button id="hook-delete" class="btn btn-xs btn-error btn-ghost">Delete</button>
        </div>
        <div class="text-[10px] text-base-content/40">
          curl -X POST ${location.origin}/h/${S(n)} -d '{"test":true}'
        </div>
        <div class="divider my-1"></div>
        <div id="hook-requests" class="space-y-2"></div>
      </div>
    `,i.querySelector("#hook-copy").addEventListener("click",()=>{navigator.clipboard.writeText(`${location.origin}/h/${n}`)}),i.querySelector("#hook-delete").addEventListener("click",async()=>{if(!confirm("Delete this endpoint?"))return;await g(`/__keyway/api/hooks/${n}`,{method:"DELETE"}),u=null,i.innerHTML='<div class="flex items-center justify-center h-full text-base-content/20">Select or create an endpoint</div>',m()});try{let o=await g(`/__keyway/api/hooks/${n}`);c(o.requests||[])}catch{}r=new EventSource(`/__keyway/api/hooks/${n}/events`),r.addEventListener("capture",(o)=>{try{let p=JSON.parse(o.data),b=document.getElementById("hook-requests");if(b){let s=document.createElement("div");s.innerHTML=x(p),b.insertBefore(s.firstElementChild,b.firstChild)}}catch{}}),m()}function c(n){let o=e.querySelector("#hook-requests");if(!o)return;o.innerHTML=n.length?n.map(x).join(""):'<div class="text-base-content/20 text-center">No captures yet</div>'}function x(n){return`
      <div class="bg-base-200 p-2 rounded space-y-1">
        <div class="flex items-center gap-2">
          <span class="method-${n.method} font-semibold text-[11px]">${n.method}</span>
          <span class="text-base-content/50 text-[10px]">${S(n.path||"")}</span>
          <span class="ml-auto text-[10px] text-base-content/20">${n.ts||""}</span>
        </div>
        ${n.body?`<pre class="text-[10px] text-base-content/40 whitespace-pre-wrap max-h-20 overflow-auto">${S(n.body)}</pre>`:""}
      </div>
    `}return a.addEventListener("click",async()=>{let n=await g("/__keyway/api/hooks",{method:"POST"});await m(),l(n.hook.id)}),m().then(()=>{let n=v.get("navigate_to_hook");if(n)v.set("navigate_to_hook",void 0),l(n)}),()=>{if(r)r.close()}}function fe(e){return e.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")}function ie(e){e.innerHTML=`
    <div class="flex flex-col h-full">
      <div class="flex items-center gap-3 px-4 py-2 border-b border-base-300 bg-base-200/50">
        <h2 class="text-sm font-semibold text-base-content/80">WebSocket</h2>
      </div>
      <div class="flex flex-1 overflow-hidden">
        <div class="flex-1 flex flex-col">
          <div id="ws-messages" class="flex-1 overflow-y-auto p-3 space-y-1"></div>
          <div class="flex gap-2 p-3 border-t border-base-300">
            <input id="ws-input" type="text" placeholder='{"cmd":"ping"}'
              class="input input-sm input-bordered bg-base-100 flex-1 text-[11px]" />
            <button id="ws-send" class="btn btn-sm btn-primary">Send</button>
          </div>
        </div>
        <div class="w-48 border-l border-base-300 p-3 space-y-3">
          <div class="text-[10px] text-base-content/40 font-medium">Quick Commands</div>
          <div class="space-y-1" id="ws-quick-cmds"></div>
          <div class="text-[9px] text-base-content/30 space-y-1 pt-2 border-t border-base-300/30">
            <div class="font-medium text-base-content/40">Advanced</div>
            <div>{"cmd":"trigger","id":"..."}</div>
            <div>{"cmd":"send_hook","id":"...","body":"..."}</div>
          </div>
        </div>
      </div>
    </div>
  `;let t=e.querySelector("#ws-messages"),i=e.querySelector("#ws-input"),a=e.querySelector("#ws-send"),u=e.querySelector("#ws-quick-cmds"),r=[{label:"Ping",cmd:{cmd:"ping"}},{label:"Info",cmd:{cmd:"info"}},{label:"Scripts",cmd:{cmd:"scripts"}},{label:"Hooks",cmd:{cmd:"hooks"}}];for(let c of r){let x=document.createElement("button");x.className="btn btn-xs btn-ghost w-full justify-start text-[10px] text-base-content/50",x.textContent=c.label,x.addEventListener("click",()=>{R(c.cmd),m("out",JSON.stringify(c.cmd))}),u.appendChild(x)}function m(c,x){let n=document.createElement("div"),o=c==="out"?"→":"←",p=c==="out"?"text-primary":"text-info",b=x;try{b=JSON.stringify(JSON.parse(x),null,2)}catch{}n.className=`text-[10px] ${p}`,n.innerHTML=`<span class="text-base-content/20">${o}</span> <pre class="inline whitespace-pre-wrap">${fe(b)}</pre>`,t.appendChild(n),t.scrollTop=t.scrollHeight}function f(){let c=i.value.trim();if(!c)return;try{let x=JSON.parse(c);R(x),m("out",c)}catch{R({cmd:c}),m("out",JSON.stringify({cmd:c}))}i.value=""}a.addEventListener("click",f),i.addEventListener("keydown",(c)=>{if(c.key==="Enter")f()});let l=v.on("ws_messages",(c)=>{if(!c||c.length===0)return;let x=c[c.length-1];m("in",JSON.stringify(x))});return C(),()=>l()}function E(e){return e.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")}function V(e){if(!e||e===0)return"-";if(e<1000)return e+"us";if(e<1e6)return(e/1000).toFixed(1)+"ms";return(e/1e6).toFixed(2)+"s"}function re(e){e.innerHTML=`
    <div class="flex flex-col h-full">
      <div class="flex items-center gap-3 px-4 py-2 border-b border-base-300 bg-base-200/50">
        <h2 class="text-sm font-semibold text-base-content/80">Metrics</h2>
        <div class="flex-1"></div>
        <button id="metrics-refresh" class="btn btn-xs btn-ghost text-base-content/50">Refresh</button>
      </div>
      <div id="metrics-content" class="flex-1 overflow-y-auto p-4 space-y-4"></div>
    </div>
  `;let t=e.querySelector("#metrics-content"),i=e.querySelector("#metrics-refresh"),a,u=null,r=null;async function m(){try{let o=await g("/__keyway/api/metrics");r=o,f(o)}catch{t.innerHTML='<div class="text-error">Failed to load metrics</div>'}}function f(o){let p=o.latency||{min_us:0,avg_us:0,max_us:0};t.innerHTML=`
      <div id="metric-cards" class="grid grid-cols-3 gap-3">
        ${l("requests","Requests",String(o.total_requests||0),"text-base-content")}
        ${l("connections","Connections",String(o.active_connections||0),"text-info")}
        ${l("errors","Errors",String(o.total_errors||0),o.total_errors>0?"text-error":"text-base-content/50")}
        ${l(null,"Status",o.status||"unknown",o.status==="ok"?"text-success":"text-error")}
        ${l(null,"Workers",String(o.worker_count||0),"text-primary")}
        ${l(null,"Rejected",String(o.rejected_connections||0),o.rejected_connections>0?"text-warning":"text-base-content/50")}
        ${l("scripts","Scripts","-","text-primary")}
      </div>
      <div id="drill-down"></div>
      <div class="divider my-2"></div>
      <div class="text-[10px] text-base-content/40 font-medium mb-2">Latency</div>
      <div class="grid grid-cols-3 gap-3">
        ${l(null,"Min",V(p.min_us),"text-success")}
        ${l(null,"Avg",V(p.avg_us),"text-warning")}
        ${l(null,"Max",V(p.max_us),"text-error")}
      </div>
      <div class="divider my-2"></div>
      <div id="metrics-counters"></div>
    `,t.querySelectorAll("[data-drill]").forEach((b)=>{b.addEventListener("click",()=>{let s=b.dataset.drill;u=u===s?null:s,c()})}),c(),n()}function l(o,p,b,s){let d=o?`data-drill="${o}"`:"";return`
      <div class="bg-base-200 rounded p-3 ${o?"cursor-pointer hover:bg-base-300 transition-colors":""} ${o&&u===o?"ring-1 ring-primary/50":""}" ${d}>
        <div class="text-[10px] text-base-content/40">${E(p)}</div>
        <div class="text-sm font-semibold ${s} mt-0.5">${E(b)}</div>
      </div>
    `}function c(){let o=t.querySelector("#drill-down");if(!o)return;if(!u){o.innerHTML="";return}let p=v.get("traffic")||[];if(u==="errors"){let b=p.filter((s)=>s.status>=400).slice(0,20);o.innerHTML=`
        <div class="mt-3 bg-base-200 rounded p-3">
          <div class="text-[10px] text-base-content/40 font-medium mb-2">Recent Errors (4xx/5xx)</div>
          ${b.length===0?'<div class="text-[10px] text-base-content/30">No errors in traffic history</div>':`<div class="space-y-0.5">${b.map((s)=>`
              <div class="flex items-center gap-2 text-[10px] py-0.5">
                <span class="w-[50px] shrink-0">${P(s.method)}</span>
                <span class="flex-1 text-base-content/60 truncate">${E(s.path)}</span>
                <span>${j(s.status)}</span>
                <span class="text-base-content/40">${s.latency}</span>
              </div>
            `).join("")}</div>`}
        </div>
      `}else if(u==="requests"){let b=p.length,s={};for(let d of p)s[d.method]=(s[d.method]||0)+1;o.innerHTML=`
        <div class="mt-3 bg-base-200 rounded p-3">
          <div class="text-[10px] text-base-content/40 font-medium mb-2">Request Breakdown (from traffic buffer)</div>
          <div class="space-y-0.5">
            <div class="flex items-center gap-2 text-[10px] py-0.5">
              <span class="text-base-content/40 w-20">Total</span>
              <span class="text-base-content/70">${b}</span>
            </div>
            ${Object.entries(s).sort((d,h)=>h[1]-d[1]).map(([d,h])=>`
              <div class="flex items-center gap-2 text-[10px] py-0.5">
                <span class="w-20">${P(d)}</span>
                <span class="text-base-content/70">${h}</span>
                <span class="text-base-content/30">(${b>0?(h/b*100).toFixed(0):0}%)</span>
              </div>
            `).join("")}
          </div>
        </div>
      `}else if(u==="connections"){let b={};for(let s of p){let d=s.worker_id||"-";b[d]=(b[d]||0)+1}o.innerHTML=`
        <div class="mt-3 bg-base-200 rounded p-3">
          <div class="text-[10px] text-base-content/40 font-medium mb-2">Worker Distribution (from traffic buffer)</div>
          ${Object.keys(b).length===0?'<div class="text-[10px] text-base-content/30">No traffic data</div>':`<div class="space-y-0.5">${Object.entries(b).sort((s,d)=>d[1]-s[1]).map(([s,d])=>`
              <div class="flex items-center gap-2 text-[10px] py-0.5">
                <span class="text-base-content/40 w-20">Worker ${E(s)}</span>
                <span class="text-base-content/70">${d} reqs</span>
              </div>
            `).join("")}</div>`}
          ${r?`<div class="mt-2 pt-2 border-t border-base-300/30 text-[10px] text-base-content/40">Active connections: ${r.active_connections}</div>`:""}
        </div>
      `}else if(u==="scripts")o.innerHTML=`
        <div class="mt-3 bg-base-200 rounded p-3">
          <div class="text-[10px] text-base-content/40 font-medium mb-2">Loading scripts...</div>
        </div>
      `,x(o)}async function x(o){try{let b=(await g("/__keyway/api/scripts")).scripts||[],s=b.filter((d)=>d.enabled);o.innerHTML=`
        <div class="mt-3 bg-base-200 rounded p-3">
          <div class="text-[10px] text-base-content/40 font-medium mb-2">Scripts (${s.length} enabled / ${b.length} total)</div>
          ${b.length===0?'<div class="text-[10px] text-base-content/30">No scripts</div>':`<div class="space-y-0.5">${b.map((d)=>`
              <div class="flex items-center gap-2 text-[10px] py-0.5">
                <a class="flex-1 text-primary cursor-pointer hover:underline script-nav" data-script-id="${E(d.id)}">${E(d.name)}</a>
                <span class="badge badge-xs ${d.enabled?"badge-success":"badge-ghost"}">${d.enabled?"on":"off"}</span>
                <span class="text-base-content/50 w-16 text-right">${d.metrics.calls} calls</span>
                <span class="text-base-content/40 w-16 text-right">${d.metrics.errors} err</span>
                <span class="text-base-content/40 w-20 text-right">${V(d.metrics.avg_latency_us)}</span>
              </div>
            `).join("")}</div>`}
        </div>
      `,o.querySelectorAll(".script-nav").forEach((d)=>{d.addEventListener("click",()=>{$("/scripts",{navigate_to_script:d.dataset.scriptId})})})}catch{o.innerHTML='<div class="mt-3 text-error text-[10px]">Failed to load scripts</div>'}}async function n(){let o=e.querySelector("#metrics-counters");if(!o)return;try{let p=await g("/__keyway/api/counters");o.innerHTML=`
        <div class="text-[10px] text-base-content/40 font-medium mb-2">Worker Counters</div>
        <div class="grid grid-cols-3 gap-3">
          ${Object.entries(p).map(([b,s])=>l(null,b.replace(/_/g," "),String(s),"text-base-content/60")).join("")}
        </div>
      `}catch{}}let _vh=()=>{document.hidden?clearInterval(a):(a=setInterval(m,5000))};return document.addEventListener("visibilitychange",_vh),i.addEventListener("click",m),m(),a=setInterval(m,5000),()=>{clearInterval(a),document.removeEventListener("visibilitychange",_vh)}}w("/traffic","Traffic","◉",F);w("/scripts","Scripts","λ",ne);w("/probe","Probe","⇄",se);w("/hooks","Hooks","⇥",ae);w("/ws","WebSocket","⇌",ie);w("/metrics","Metrics","▦",re);var{content:xe,cleanup:st}=I();B(xe);U();C();
