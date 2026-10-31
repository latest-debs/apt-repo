/**
 * External liveness watchdog checks.
 *
 * This is the only alarm that runs outside the org it watches, so a bug
 * here is silent by construction: it reports healthy while the archive is
 * down, and nothing else is looking. Run:
 *
 *     node test-watchdog.mjs
 */
import assert from "node:assert/strict";

import { checkOrigin } from "./src/worker.js";

const ENV = {
  ORIGIN_BASE: "https://latest-debs.github.io/apt-repo/",
  PUBLIC_BASE: "https://latest-debs.example.workers.dev",
  WATCHDOG_SUITE: "trixie",
};

const fresh = () => new Date(Date.now() - 3600_000).toUTCString();
const release = (date) => `Origin: latest-debs\nDate: ${date}\nSuite: trixie\n`;
const index = "Package: uv\nFilename: pool/trixie/uv/uv_0.9.7-1.trixie_amd64.deb\n";

const ok = (body) => ({ ok: true, status: 200, text: async () => body, headers: new Map() });
const code = (status) => ({ ok: false, status, text: async () => "", headers: new Map() });
const redirect = (location) => ({
  ok: false,
  status: 302,
  text: async () => "",
  headers: new Map([["location", location]]),
});

// Routes every URL the check can ask for; each case overrides one of them.
function stub(overrides = {}) {
  const routes = {
    release: ok(release(fresh())),
    self: ok(release(fresh())),
    index: ok(index),
    pool: redirect("https://github.com/latest-debs/uv-debian/releases/download/v1/uv.deb"),
    asset: ok(""),
    ...overrides,
  };
  const seen = [];
  const impl = async (url, init) => {
    seen.push(url);
    if (url.startsWith("https://github.com/")) return routes.asset;
    if (url.includes("//dists/")) return routes.self;
    if (url.includes("/pool/")) return routes.pool;
    if (url.includes("/Packages")) return routes.index;
    if (url.endsWith("/Release")) return routes.release;
    throw new Error(`unrouted ${url}`);
  };
  impl.seen = seen;
  return impl;
}

// --- healthy ------------------------------------------------------------
const healthy = stub();
assert.deepEqual(await checkOrigin(ENV, healthy), [], "a healthy origin reports nothing");
assert.ok(
  healthy.seen.some((u) => u.includes("//dists/trixie/Release")),
  "the self-check must use the double-slash form apt sends",
);
assert.ok(
  healthy.seen.some((u) => u.startsWith("https://github.com/")),
  "the pool check must follow the 302 through to the release asset",
);

// --- each failure mode is caught, and named ------------------------------
const fails = async (overrides, needle) => {
  const out = await checkOrigin(ENV, stub(overrides));
  assert.equal(out.length, 1, `expected exactly one failure, got: ${out.join("; ")}`);
  assert.match(out[0], needle);
};

await fails({ release: code(404) }, /origin dists\/trixie\/Release -> HTTP 404/);
await fails({ self: code(404) }, /worker \/\/dists\/trixie\/Release -> HTTP 404/);
await fails({ index: code(500) }, /Packages -> HTTP 500/);
await fails({ index: ok("Package: uv\n") }, /lists no Filename:/);
await fails({ pool: code(404) }, /expected a 302/);
// The failure the whole check exists for: apt update succeeds, every apt
// install 404s, and CI stays green throughout.
await fails({ asset: code(404) }, /302s to .* -> HTTP 404/);

// A stale Release is the "rebuild silently stopped" case; a fresh one at the
// window edge must not cry wolf.
const staleBy = (hours) => ok(release(new Date(Date.now() - hours * 3600_000).toUTCString()));
await fails({ release: staleBy(72) }, /stamped 72h ago .*rebuild has stopped/);
assert.deepEqual(
  await checkOrigin(ENV, stub({ release: staleBy(47) })),
  [],
  "inside the window is healthy",
);
assert.deepEqual(
  await checkOrigin({ ...ENV, WATCHDOG_STALE_HOURS: 12 }, stub({ release: staleBy(24) })).then(
    (f) => f.length,
  ),
  1,
  "WATCHDOG_STALE_HOURS must tighten the window",
);

await fails({ release: ok("Origin: latest-debs\nSuite: trixie\n") }, /no parsable Date:/);

// A thrown fetch must be reported, not propagated - the scheduled handler
// has nobody to catch it.
assert.match(
  (await checkOrigin(ENV, async () => { throw new Error("boom"); }))[0],
  /threw: boom/,
);

// With no PUBLIC_BASE the origin check still runs; the two hops that need
// it are skipped rather than reported as failures.
assert.deepEqual(await checkOrigin({ ...ENV, PUBLIC_BASE: "" }, stub({ pool: code(404) })), []);

console.log("ok - checkOrigin: healthy, stale, 404, dead 302 target, throw, no PUBLIC_BASE");
