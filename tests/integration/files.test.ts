// File API CRUD round-trip (#118) — write / read / list / delete over the
// dashboard's file endpoints (see dashboard/keyway.lua, __keyway_file_*).
//
// Operates on a THROWAWAY probe file (dashboard/kw118-probe.lua) that is not
// tracked in git, so a mid-run SIGKILL leaves at worst an untracked `??`
// file — never a modified tracked source. No entrypoint mutation, no reload:
// reload only re-runs the --script entrypoint, so "new file -> reload ->
// route live" isn't a real contract; this tests the file API itself.

import { describe, test, expect, afterAll } from "bun:test";

const base = () => globalThis.__KEYWAY_BASE;

const PROBE = "kw118-probe.lua"; // /__keyway/api/files/{path} prefixes with "dashboard/"
const CONTENT = "-- kw118 file API probe\nreturn 118\n"; // valid Lua (.lua writes are loadstring-validated)

const filesUrl = () => `${base()}/__keyway/api/files`;
const fileUrl = () => `${filesUrl()}/${PROBE}`;

async function deleteProbe() {
  return fetch(fileUrl(), { method: "DELETE" });
}

async function listProbePaths(): Promise<string[]> {
  const res = await fetch(filesUrl());
  const { files } = await res.json();
  return files.map((f: { path: string }) => f.path);
}

// Idempotent teardown: worst case leaves nothing tracked-modified.
afterAll(async () => {
  await deleteProbe();
});

describe("file API CRUD round-trip", () => {
  test("write -> read -> list -> delete a throwaway file", async () => {
    // Idempotent start: clear any leftover probe from a killed prior run.
    await deleteProbe();

    try {
      // -- write --
      const put = await fetch(fileUrl(), {
        method: "PUT",
        body: JSON.stringify({ content: CONTENT }),
      });
      expect(put.status).toBe(200);
      expect((await put.json()).ok).toBe(true);

      // -- read back: content matches what we wrote --
      const read = await fetch(fileUrl());
      expect(read.status).toBe(200);
      expect((await read.json()).content).toBe(CONTENT);

      // -- list: probe appears in the tree --
      expect(await listProbePaths()).toContain(PROBE);
    } finally {
      // -- delete --
      const del = await deleteProbe();
      expect(del.status).toBe(200);
    }

    // -- gone: read 404s and it's absent from the listing --
    expect((await fetch(fileUrl())).status).toBe(404);
    expect(await listProbePaths()).not.toContain(PROBE);
  });
});
