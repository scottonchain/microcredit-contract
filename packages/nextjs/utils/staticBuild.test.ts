import assert from "node:assert/strict";
import { test } from "node:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

function fixture(t: { after: (cleanup: () => void) => void }, result: number) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "microcredit-static-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  fs.mkdirSync(path.join(dir, "scripts"));
  fs.mkdirSync(path.join(dir, "bin"));
  fs.mkdirSync(path.join(dir, "out"));
  fs.writeFileSync(path.join(dir, "scaffold.target.ts"), "original target\n");
  fs.writeFileSync(path.join(dir, "out/index.html"), "previous release");
  fs.copyFileSync(new URL("../scripts/build-static.sh", import.meta.url), path.join(dir, "scripts/build-static.sh"));
  fs.writeFileSync(path.join(dir, "bin/yarn"), `#!/bin/sh\nmkdir -p out\nprintf 'new release' > out/index.html\nexit ${result}\n`, { mode: 0o755 });
  const run = (extraEnvironment: Record<string, string> = {}) => spawnSync("bash", ["scripts/build-static.sh"], { cwd: dir, env: {
    ...process.env, PATH: path.join(dir, "bin") + path.delimiter + process.env.PATH, NEXT_PUBLIC_BUILD_COMMIT: "test-build",
    ...extraEnvironment,
  }, encoding: "utf8" });
  return { dir, run };
}

test("failed static builds preserve the original target, export and failing exit status", t => {
  const { dir, run } = fixture(t, 17);
  assert.equal(run().status, 17);
  assert.equal(fs.readFileSync(path.join(dir, "scaffold.target.ts"), "utf8"), "original target\n");
  assert.equal(fs.readFileSync(path.join(dir, "out/index.html"), "utf8"), "previous release");
  assert.equal(fs.existsSync(path.join(dir, ".static-build-lock")), false);
});

test("successful static builds replace output and restore the source target", t => {
  const { dir, run } = fixture(t, 0);
  const target = path.join(dir, "scaffold.target.ts");
  const oldTime = new Date("2001-01-01T00:00:00Z");
  fs.utimesSync(target, oldTime, oldTime);
  assert.equal(run().status, 0);
  assert.equal(fs.readFileSync(path.join(dir, "out/index.html"), "utf8"), "new release");
  assert.equal(fs.readFileSync(target, "utf8"), "original target\n");
  assert.ok(fs.statSync(target).mtimeMs > oldTime.getTime(), "restoration must invalidate file watchers");
});

test("another build cannot overwrite the target or remove the first build's lock", t => {
  const { dir, run } = fixture(t, 0);
  fs.mkdirSync(path.join(dir, ".static-build-lock"));
  assert.equal(run().status, 1);
  assert.equal(fs.existsSync(path.join(dir, ".static-build-lock")), true);
  assert.equal(fs.readFileSync(path.join(dir, "out/index.html"), "utf8"), "previous release");
});

test("failure before backing up the export preserves the previous release", t => {
  const { dir, run } = fixture(t, 0);
  fs.unlinkSync(path.join(dir, "scaffold.target.ts"));
  assert.notEqual(run().status, 0);
  assert.equal(fs.readFileSync(path.join(dir, "out/index.html"), "utf8"), "previous release");
  assert.equal(fs.existsSync(path.join(dir, ".static-build-lock")), false);
});

test("an incomplete target backup never replaces the original target", t => {
  const { dir, run } = fixture(t, 0);
  // Simulate cp creating a partial destination before reporting an I/O failure.
  fs.writeFileSync(path.join(dir, "bin/cp"), `#!/bin/sh
for destination in "$@"; do :; done
printf 'partial backup' > "$destination"
exit 23
`, { mode: 0o755 });
  assert.equal(run().status, 23);
  assert.equal(fs.readFileSync(path.join(dir, "scaffold.target.ts"), "utf8"), "original target\n");
  assert.equal(fs.readFileSync(path.join(dir, "out/index.html"), "utf8"), "previous release");
  assert.equal(fs.existsSync(path.join(dir, ".static-build-lock")), false);
});

test("an interruption immediately after moving the export restores it", t => {
  const { dir, run } = fixture(t, 0);
  const lookup = spawnSync("sh", ["-c", "command -v mv"], { encoding: "utf8" });
  assert.equal(lookup.status, 0);
  // The child signals the wrapper at the command boundary, before its next assignment.
  fs.writeFileSync(path.join(dir, "bin/mv"), `#!/bin/sh
"$STATIC_TEST_REAL_MV" "$@" || exit "$?"
if [ "$1" = "out" ]; then kill -TERM "$PPID"; fi
`, { mode: 0o755 });
  assert.equal(run({ STATIC_TEST_REAL_MV: lookup.stdout.trim() }).status, 143);
  assert.equal(fs.readFileSync(path.join(dir, "scaffold.target.ts"), "utf8"), "original target\n");
  assert.equal(fs.readFileSync(path.join(dir, "out/index.html"), "utf8"), "previous release");
  assert.equal(fs.existsSync(path.join(dir, ".static-build-lock")), false);
});
