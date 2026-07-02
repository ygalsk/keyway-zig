# Stage 1: Build
FROM debian:bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates xz-utils libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# Install Zig 0.16.0
ADD https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz /tmp/zig.tar.xz
RUN tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-x86_64-linux-0.16.0/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /build

COPY build.zig build.zig.zon ./
COPY src/ src/
COPY lua/ lua/
COPY vendor/ vendor/

RUN zig build -Doptimize=ReleaseFast

# Stage 2: Runtime
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /build/zig-out/bin/keyway .
COPY dashboard/ dashboard/
COPY examples/ examples/
COPY lua/ lua/

EXPOSE 8080

ENTRYPOINT ["./keyway"]
CMD ["--script", "examples/minimal.lua"]
