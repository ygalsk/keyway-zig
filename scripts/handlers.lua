-- handlers.lua — Route registration for Keyway Phase 1
-- Loaded independently by each worker thread at startup.

-- Module imports (top of file, before any route registration)
local styles   = require("keyway.styles")
local template = require("keyway.template")
local form     = require("keyway.form")

-- Load templates once at startup (each worker independently)
template.load("layout")
template.load("home")

-- Helper: render a full page through the layout
local function render_page(page_name, vars)
    vars = vars or {}
    vars.worker_id = keyway.worker_id
    vars.page = page_name
    vars.content = template.render(page_name, vars)
    return template.render("layout", vars)
end

-- Route table
keyway.routes = {
    ["/style.css"] = {
        GET = function(ctx)
            ctx.status = 200
            ctx.headers["Content-Type"] = "text/css; charset=utf-8"
            ctx.headers["Cache-Control"] = "public, max-age=86400"
            ctx.body = styles.css
        end,
    },

    ["/"] = {
        GET = function(ctx)
            ctx.status = 200
            ctx.headers["Content-Type"] = "text/html; charset=utf-8"
            ctx.body = render_page("home", {})
        end,
    },

    ["/echo"] = {
        POST = function(ctx)
            local fields = form.parse(ctx.body or "")
            ctx.status = 200
            ctx.headers["Content-Type"] = "text/html; charset=utf-8"
            ctx.body = render_page("home", {
                echo_fields = fields,
                success_msg = "Form parsed successfully",
            })
        end,
    },
}
