-- keyway.template — etlua template loader and renderer
-- Wraps etlua with a load/render API using a module-level cache.
-- Usage:
--   local tmpl = require("keyway.template")
--   tmpl.load("page")              -- loads scripts/templates/page.html
--   local html = tmpl.render("page", { title = "Hello" })

local etlua = require("etlua")

local M = {}

-- Compiled template cache: name -> compiled function
local _cache = {}

--- Load and compile a template from disk.
-- Opens scripts/templates/{name}.html, reads the full source, compiles it
-- with etlua, and stores the compiled function in _cache[name].
-- Errors on file-not-found or compile failure.
-- @param name  Template name without path or extension (e.g. "index")
function M.load(name)
    local path = "scripts/templates/" .. name .. ".html"
    local f, err = io.open(path, "r")
    if not f then
        error("template.load: cannot open '" .. path .. "': " .. (err or "unknown error"))
    end
    local source = f:read("*a")
    f:close()

    local compiled, compile_err = etlua.compile(source)
    if not compiled then
        error("template.load: compile error in '" .. path .. "': " .. (compile_err or "unknown error"))
    end

    _cache[name] = compiled
end

--- Render a previously loaded template with the given variables.
-- Calls the compiled function with vars (defaults to empty table).
-- Returns the rendered HTML string.
-- Errors if the template has not been loaded.
-- @param name  Template name (must have been passed to load() first)
-- @param vars  Table of variables available in the template (optional)
-- @return      Rendered HTML string
function M.render(name, vars)
    local fn = _cache[name]
    if not fn then
        error("template.render: template '" .. name .. "' not loaded — call template.load('" .. name .. "') first")
    end
    return fn(vars or {})
end

return M
