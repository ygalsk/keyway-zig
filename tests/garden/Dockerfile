# HTTP Garden target image for keyway, in the garden's own convention:
# built from source, listening on :80, forwarding to the garden's echo server.
#
# Keyway is registered as a `transducer`, not an `origin`. The garden's origin
# contract requires the server to echo its own parse as JSON (method, uri,
# ordered headers, body, all base64) — keyway's router has no catch-all and no
# arbitrary-method route, so an origin adapter would mean new engine surface
# built solely for a test tool. Transducer mode needs none of that, and it is
# the mode that matches what keyway is: a gateway. The garden sends a request
# to keyway and reads, byte for byte, what keyway forwarded upstream.
FROM http-garden-soil:latest

RUN apt -y update \
 && apt -y install --no-install-recommends xz-utils \
 && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.16.0
ADD https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz /tmp/zig.tar.xz
RUN tar -xf /tmp/zig.tar.xz -C /opt \
 && ln -s /opt/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig \
 && rm /tmp/zig.tar.xz

ARG APP_REPO
RUN git clone "$APP_REPO" keyway

ARG APP_BRANCH
ARG APP_VERSION
# The soil image sets CFLAGS/LDFLAGS with sanitizers for its C targets; zig
# manages its own toolchain flags and inherits nothing useful from them.
RUN cd /app/keyway \
 && git fetch origin "$APP_BRANCH" \
 && git checkout "$APP_VERSION" \
 && zig build -Doptimize=ReleaseFast

ARG CONFIG_FILE
COPY $CONFIG_FILE /app/keyway.lua

ARG BACKEND_HOST=127.0.0.1
ARG BACKEND_PORT=56062
RUN sed -i -e "s/BACKEND_HOST_PLACEHOLDER/$BACKEND_HOST/g" \
           -e "s/BACKEND_PORT_PLACEHOLDER/$BACKEND_PORT/g" /app/keyway.lua

ARG START_SCRIPT
COPY $START_SCRIPT /app/start.sh
CMD ["/app/start.sh"]
