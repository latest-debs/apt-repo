/**
 * Path classification checks for the redirector's usage analytics.
 *
 * The blobs written to Analytics Engine are only as good as this parsing:
 * a wrong arch here silently produces a wrong arch breakdown, which is the
 * single number MARKET-ANALYSIS.md's positioning decision hangs on. Run:
 *
 *     node test-classify.mjs
 */
import assert from "node:assert/strict";

import {
  classify,
  archFromFilename,
  clientDigest,
  normalizePath,
  originUrlFor,
} from "./src/worker.js";

const ORIGIN = "https://latest-debs.github.io/apt-repo/";

// Mirrors src/worker.js. Kept in step by the round-trip cases below, which
// feed real pool paths through this exact regex.
const POOL_PATH = /^\/pool\/([^/]+)\/([^/]+)\/([^/]+)$/;

const pool = (pathname) => classify(pathname, pathname.match(POOL_PATH));

// --- pool downloads: arch comes off the filename, not the path ----------
assert.deepEqual(
  pool("/pool/trixie/uv/uv_0.9.7-1.trixie_amd64.deb"),
  { kind: "pool", suite: "trixie", arch: "amd64", pkg: "uv" },
);
assert.deepEqual(
  pool("/pool/sid/ripgrep/ripgrep_14.1.1-1.sid_riscv64.deb").arch,
  "riscv64",
);
// The exotic arches are the whole differentiator - they must not fall to "-".
for (const arch of ["s390x", "ppc64el", "loong64", "armel", "armhf", "i386"]) {
  assert.equal(
    pool(`/pool/bookworm/fzf/fzf_0.60.0-1.bookworm_${arch}.deb`).arch,
    arch,
    `arch ${arch} must survive classification`,
  );
}

// --- source packages ----------------------------------------------------
assert.equal(archFromFilename("uv_0.9.7-1.trixie.dsc"), "source");
assert.equal(archFromFilename("uv_0.9.7-1.trixie.debian.tar.xz"), "source");
assert.equal(archFromFilename("uv_0.9.7.orig.tar.gz"), "source");

// --- indexes ------------------------------------------------------------
assert.deepEqual(
  classify("/dists/trixie/main/binary-arm64/Packages.gz", null),
  { kind: "index", suite: "trixie", arch: "arm64", pkg: "-" },
);
// Suite-wide index files carry no architecture.
assert.deepEqual(
  classify("/dists/forky/InRelease", null),
  { kind: "index", suite: "forky", arch: "-", pkg: "-" },
);
assert.equal(classify("/dists/bullseye/Release", null).arch, "-");

// --- everything else ----------------------------------------------------
assert.deepEqual(
  classify("/latest-debs.asc", null),
  { kind: "other", suite: "-", arch: "-", pkg: "-" },
);
assert.equal(classify("/", null).kind, "other");
// A pool path that does not match the 3-segment shape is not a pool hit.
assert.equal(pool("/pool/trixie/uv/nested/uv.deb").kind, "other");

// --- double-slash handling ---------------------------------------------
// Regression: extrepo's tools/validate-repo joins the base URI (trailing
// "/") with "/dists/...", producing "//dists/...". The Worker used to strip
// only one leading slash, leaving an absolute path that `new URL` resolved
// against the origin's ROOT - dropping "/apt-repo/" and 404ing every
// Release file, which failed upstream validation of the whole repository.
assert.equal(normalizePath("//dists/bookworm/Release"), "/dists/bookworm/Release");
assert.equal(normalizePath("///pool//trixie/uv/uv.deb"), "/pool/trixie/uv/uv.deb");
assert.equal(normalizePath("/dists/sid/InRelease"), "/dists/sid/InRelease");

assert.equal(
  originUrlFor("//dists/bookworm/Release", "", ORIGIN),
  "https://latest-debs.github.io/apt-repo/dists/bookworm/Release",
  "a double slash must still resolve under /apt-repo/",
);
assert.equal(
  originUrlFor("/dists/bookworm/Release", "", ORIGIN),
  "https://latest-debs.github.io/apt-repo/dists/bookworm/Release",
);
assert.equal(
  originUrlFor("/latest-debs.asc", "?v=2", ORIGIN),
  "https://latest-debs.github.io/apt-repo/latest-debs.asc?v=2",
);
// A doubled slash must still route to the pool handler, not the proxy.
assert.equal(
  pool(normalizePath("//pool/trixie/uv/uv_0.9.7-1.trixie_amd64.deb")).kind,
  "pool",
);

// --- client digest fails closed without a salt -------------------------
// Deploying before `wrangler secret put CLIENT_SALT` must not silently
// start recording weakly-hashed visitor IPs.
const req = {
  headers: new Headers({
    "cf-connecting-ip": "192.0.2.7",
    "user-agent": "Debian APT-HTTP/1.3 (2.9.8)",
  }),
};

assert.equal(await clientDigest(req, {}), "-", "no salt must record nothing");
assert.equal(await clientDigest(req, { CLIENT_SALT: "" }), "-");

const salted = await clientDigest(req, { CLIENT_SALT: "s3cr3t-salt" });
assert.match(salted, /^[0-9a-f]{16}$/);
assert.equal(await clientDigest(req, { CLIENT_SALT: "s3cr3t-salt" }), salted,
  "same client, same day, same salt -> stable digest");
assert.notEqual(await clientDigest(req, { CLIENT_SALT: "different" }), salted,
  "rotating the salt must break correlation");

console.log(
  "ok - classify/archFromFilename/normalizePath/originUrlFor/clientDigest",
);
