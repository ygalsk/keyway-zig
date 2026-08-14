# HTTP Garden target

Differential testing of keyway's HTTP/1.1 handling against ~40 other
implementations ([HTTP Garden](https://github.com/narfindustries/http-garden),
Narf Industries). There is no canonical RFC 9112 conformance suite; differential
fuzzing is what the field uses instead, and it is the tool that finds the
request-smuggling class this project cares about.

```sh
./tests/garden/run.sh                 # keyway + nginx, haproxy, hyper, gunicorn
./tests/garden/run.sh nginx envoy     # keyway + a chosen comparison set
```

Then, from the garden checkout:

```sh
./garden.sh repl
garden> payload 'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n' | transduce keyway | fanout | grid
```

`transduce keyway` sends the payload through keyway and captures what it
forwarded; `fanout | grid` shows how every other implementation interprets those
forwarded bytes. Disagreement between keyway's output and a downstream server's
reading of it is the bug.

## Why transducer and not origin

The garden's `origin` contract requires the server under test to answer every
request with its own parse as JSON — method, request-target, ordered headers
(duplicates preserved) and body, base64-encoded. Keyway's router is a segment
trie with a fixed seven-method table and no catch-all, so an origin adapter
would mean adding wildcard routing and an arbitrary-method path to the engine
for the sole benefit of a test tool.

`transducer` needs none of it: keyway proxies `/` to the garden's echo server,
which replies with the raw bytes it received. That is a supported production
configuration, it costs zero engine surface, and it exercises keyway as what it
actually is — a gateway. Origin-mode coverage stays available if the router ever
grows a catch-all for its own reasons.

## Requirements

Docker (not podman — the garden's tooling drives the docker SDK directly), `uv`,
and roughly 10 GB of disk for the image fleet. `run.sh` refuses to start unless
`HEAD` is pushed: the garden builds every target by cloning from GitHub, so an
unpushed commit would silently test something else.

The compose entry sets `seccomp:unconfined` — the default docker profile blocks
`io_uring_setup` and keyway's workers exit at startup without it.
