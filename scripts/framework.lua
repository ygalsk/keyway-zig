-- ============================================================================
-- PHASE 5: Async/Coroutine Framework (FUTURE FEATURE - NOT CURRENTLY USED)
-- ============================================================================
-- Target Performance: 1M+ req/s with io_uring / sendfile style I/O
--
-- Status: Staged for future implementation, not integrated yet
-- Current Phase: Phase 1-2 (radix + allocs ~338k req/s)
--
-- This framework will enable non-blocking async handlers when integrated with
-- io_uring in Phase 5. Handlers can yield during I/O operations, allowing the
-- event loop to handle other requests while waiting for I/O completion.
--
-- DO NOT USE: This code is architectural preparation. The current system uses
-- synchronous handlers (see handlers.lua) for simplicity and performance at
-- the current optimization tier.
-- ============================================================================

-- Keystone Lua Coroutine Framework
-- Manages coroutines for async HTTP handlers

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
end

framework = {}  -- Make framework global (not local)

-- Active coroutines (one per request)
framework.active_coroutines = {}

-- Handler registry (path -> handler function)
framework.handlers = {}

-- Register a handler function for a given name
-- Handlers will be wrapped in coroutines automatically
function framework.register(name, handler_fn)
    if type(handler_fn) ~= "function" then
        error("Handler must be a function")
    end
    framework.handlers[name] = handler_fn
    print(string.format("[Lua] Registered handler: %s", name))
end

-- Create and start a new coroutine for handling a request
-- Returns: coroutine ID for tracking
function framework.handle_request(handler_name, request)
    local handler = framework.handlers[handler_name]
    if not handler then
        return nil, string.format("Handler not found: %s", handler_name)
    end

    -- Create coroutine that wraps the handler
    local co = coroutine.create(function()
        return handler(request)
    end)

    -- Generate unique ID for this coroutine
    local co_id = tostring(co)
    framework.active_coroutines[co_id] = co

    -- Start the coroutine
    local success, result = coroutine.resume(co, request)

    if not success then
        -- Handler threw an error
        framework.active_coroutines[co_id] = nil
        return nil, result
    end

    -- Check if coroutine is done or yielded
    if coroutine.status(co) == "dead" then
        -- Handler completed synchronously
        framework.active_coroutines[co_id] = nil
        return result, nil
    else
        -- Handler yielded (async operation pending)
        -- Result contains yield value (e.g., async operation descriptor)
        return {
            status = "pending",
            co_id = co_id,
            yield_value = result
        }, nil
    end
end

-- Resume a coroutine with a value (result of async operation)
function framework.resume_coroutine(co_id, value)
    local co = framework.active_coroutines[co_id]
    if not co then
        return nil, "Coroutine not found"
    end

    local success, result = coroutine.resume(co, value)

    if not success then
        framework.active_coroutines[co_id] = nil
        return nil, result
    end

    if coroutine.status(co) == "dead" then
        framework.active_coroutines[co_id] = nil
        return result, nil
    else
        return {
            status = "pending",
            co_id = co_id,
            yield_value = result
        }, nil
    end
end

-- Helper: Yield for async I/O operation
-- This will be called by handler code when it needs to do async work
function framework.yield_for_io(operation)
    return coroutine.yield(operation)
end

-- Example async sleep (for testing coroutine flow)
function framework.async_sleep(seconds)
    return framework.yield_for_io({
        type = "sleep",
        duration = seconds
    })
end

-- Example async HTTP get (placeholder for Phase 5)
function framework.async_http_get(url)
    return framework.yield_for_io({
        type = "http_get",
        url = url
    })
end

return framework
