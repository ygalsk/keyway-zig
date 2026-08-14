-- HTTP Garden transducer config: forward every method and every path to the
-- garden's echo server, which replies with the raw bytes keyway sent it. The
-- placeholders are substituted at image build time (see Dockerfile).
--
-- strip_prefix = false so the request-target reaches the echo server exactly
-- as keyway chose to forward it — rewriting it here would hide the very
-- transformation the garden exists to observe.
keyway.routes = {}

keyway.proxy = {
    ["/"] = {
        host = "BACKEND_HOST_PLACEHOLDER",
        port = BACKEND_PORT_PLACEHOLDER,
        strip_prefix = false,
    },
}
