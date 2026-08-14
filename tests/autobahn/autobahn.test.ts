// WebSocket RFC 6455 conformance — Autobahn|Testsuite, the industry suite.
//
// Runs all 517 `fuzzingclient` cases against the running keyway and fails on
// any non-conforming case. Autobahn covers framing, fragmentation, reserved
// bits, control frames, close codes and UTF-8 validation far more exhaustively
// than hand-written assertions can.
//
// NOT part of `bun run test:ci` — it needs a container runtime and ~12 minutes.
//   cd tests && bun run test:autobahn
//
// Container runtime: podman is preferred. Docker Desktop on Linux runs the
// daemon inside a VM, so `--network host` is the VM's netns, not the host's,
// and the suite cannot reach keyway on 127.0.0.1.

import { beforeAll, describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { resolve } from "path";

const DIR = import.meta.dir;
// Pinned: `latest` moves, and a changed case list is indistinguishable from a
// truncated run.
const IMAGE = "docker.io/crossbario/autobahn-testsuite:25.10.1";
const SPEC = resolve(DIR, "fuzzingclient.json");
const REPORTS = resolve(DIR, "reports");

// The whole suite, nothing excluded. Every failure is tracked as its own
// issue rather than allowlisted here — a suppressed case is a case nobody
// looks at again.
const CASES = ["*"];

// UNIMPLEMENTED is Autobahn's verdict for sections 12/13 when the server does
// not negotiate permessage-deflate — it means "not applicable", not "wrong".
// Keyway does not implement the extension.
const PASSING = new Set(["OK", "NON-STRICT", "INFORMATIONAL", "UNIMPLEMENTED"]);

function runtime(): string | null {
  for (const bin of ["podman", "docker"]) {
    if (Bun.spawnSync(["which", bin]).exitCode === 0) return bin;
  }
  return null;
}

let results: Record<string, { behavior: string; behaviorClose: string }> = {};

describe("Autobahn|Testsuite RFC 6455 conformance", () => {
  beforeAll(async () => {
    const bin = runtime();
    if (!bin) throw new Error("no container runtime (podman/docker) on PATH");

    await rm(REPORTS, { recursive: true, force: true });
    await mkdir(REPORTS, { recursive: true });
    await writeFile(
      SPEC,
      JSON.stringify({
        outdir: "/ws/reports",
        servers: [
          { agent: "keyway", url: `ws://127.0.0.1:${globalThis.__KEYWAY_PORT}/test/ws` },
        ],
        cases: CASES,
        "exclude-cases": [],
        "exclude-agent-cases": {},
      })
    );

    // MUST stay async. spawnSync blocks bun's event loop for the whole ~12
    // minute run, which stops it draining the keyway stderr pipe that
    // preload.ts opens. keyway blocks in write(2) once that 64 KiB pipe fills
    // (#248), so the server froze partway through section 9 and every case
    // after it reported "The WebSocket opening handshake was never completed!".
    // That cost ~120 phantom failures and truncated the run to 386-396 cases,
    // making sections 10, 12 and 13 look broken when they pass.
    const proc = Bun.spawn([
      bin, "run", "--rm", "--network", "host",
      "-v", `${DIR}:/ws:Z`,
      IMAGE, "wstest", "-m", "fuzzingclient", "-s", "/ws/fuzzingclient.json",
    ], { stdout: "pipe", stderr: "pipe" });

    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ]);

    const index = resolve(REPORTS, "index.json");
    if (!existsSync(index)) {
      throw new Error(
        `wstest produced no report (exit ${exitCode}):\n${stderr}\n${stdout}`
      );
    }
    results = (await Bun.file(index).json()).keyway;
  });

  // A short report means wstest died partway, which would otherwise read as
  // "everything after the cut passed".
  test("runs every case in the suite", () => {
    expect(Object.keys(results).length).toBe(517);
  });

  test("every case conforms", () => {
    const failed = Object.entries(results)
      .filter(([, r]) => !PASSING.has(r.behavior))
      .map(([id, r]) => `${id}: ${r.behavior}/${r.behaviorClose}`);
    expect(failed).toEqual([]);
  });

  test("every closing handshake is clean", () => {
    const unclean = Object.entries(results)
      .filter(([, r]) => !PASSING.has(r.behaviorClose))
      .map(([id, r]) => `${id}: close ${r.behaviorClose}`);
    expect(unclean).toEqual([]);
  });
});
