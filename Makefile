.PHONY: build run test test-integration dashboard-build docker-build docker-dev up clean

build:
	zig build

run:
	zig build run

test:
	zig build test

test-integration:
	cd tests && CLAUDECODE=1 bun test --bail --timeout 10000

dashboard-build:
	cd dashboard/ui && bun run build

docker-build:
	docker build -t keyway .

docker-dev:
	docker build -f Dockerfile.dev -t keyway-dev .

up:
	docker compose up

clean:
	rm -rf zig-out .zig-cache
