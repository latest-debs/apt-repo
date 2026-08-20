# apt-repo redirector

Cloudflare Worker implementing step 4 of `PLATFORM-EVALUATION.md`'s
Decision: the single origin apt clients hit, splitting `/pool/*` (redirect
to the tool's own GitHub Release asset) from everything else (`/dists/*`,
signing key, `index.html`, ... — proxied straight from the existing
GitHub Pages site, unchanged).

## Why this exists

apt resolves the `Filename:` field in a `Packages` index relative to the
repo's base URI — verified directly (see `PLATFORM-EVALUATION.md`, step 4):
a test repo with `Filename:` pointing at a different host produced a
broken `<base>/<other-host>/...` concatenation and a 404, never the real
file. `dists/` and `pool/` must therefore share one origin, and GitHub
Pages can't run the redirect logic `pool/` needs. This Worker is that
shared origin.

## How it works

- `GET /pool/<suite>/<pkg>/<filename>` → look up `<pkg>` in
  `pkg-repo-map.json` (emitted by `scripts/build-repo.sh` into `dists/`,
  reusing the `{repo, tag}` it already fetches per tool — no extra GitHub
  API calls from the Worker) → 302 to
  `https://github.com/<repo>/releases/download/<tag>/<filename>`.
- Everything else → proxied from `ORIGIN_BASE` (currently the production
  `apt-repo` GitHub Pages site) unchanged.
- The manifest fetch is cached via the Workers Cache API (`cf.cacheTtl:
  60`), so a cold Worker instance costs one extra fetch, not one per
  request.

**Verified locally, against real release data pulled live from six
`*-debian` repos** (`ripgrep`, `uv`, `bat`, `k9s`, `rclone`, `difftastic` —
chosen to spread across suites, archs, and both `v`-prefixed and bare
release tags):

- 22 pool-path redirects across bookworm/trixie/forky/sid and
  amd64/arm64/armhf/s390x/i386/ppc64el/riscv64 all resolved to the correct
  `github.com/<repo>/releases/download/<tag>/<filename>` URL — including
  the `v0.26.1+1`/`v0.51.0+1`/`v1.75.0+1`-style tags, which a
  filename-derived tag (rather than this manifest's stored `tag` field)
  would have gotten wrong.
- One real download of each file kind confirmed as genuinely valid, not
  just a 200: `.deb` (`ar t`: `debian-binary`, `control.tar.xz`,
  `data.tar.xz`), `.dsc` (real Debian control-file text), `.debian.tar.xz`
  and `.orig.tar.xz` (valid XZ magic bytes).
- Confirmed against GitHub directly that a literal `+` vs `%2B` in the
  filename path segment resolve to the identical backing asset (same
  release-asset blob ID) — package filenames
  (`<pkg>_<version>-<build>+<suite>_<arch>.deb`) don't need percent-encoding
  here.
- Edge cases: unknown package → clean 404 from the Worker itself. A
  filename that doesn't exist in that release (wrong arch) → Worker still
  302s (it doesn't validate asset existence, by design) but the client's
  next hop lands on a real 404 from GitHub, not a silent failure. Manifest
  origin unreachable → 502 from the Worker, distinguishable from a GitHub
  404; confirmed both the cached-manifest case (serves fine) and the
  cold/uncached case (502) on a fresh instance.

**Full-catalog run, 2026-08-20**: every tracked tool in `tools.yaml` (41),
against real `releases/latest` data pulled live for each. All 41 had a
published release (no `no-release` skips). **All 749 real assets across
every tool redirected to the exact expected URL** — bookworm/trixie/forky/sid,
9 distinct archs including `loong64` and `armel` (present in the real data
for `fzf`/`just`/`yq-go`/`bottom`/`nushell`/`du-dust` — outside this
repo's own README-documented arch list, unrelated to the redirector but
worth a maintainer's separate look), and 546 `.deb` / 90 `.dsc` / 90
`.debian.tar.xz` / 23 `.orig.tar.xz` files. 32 of the 41 tools use
`v`-prefixed release tags, 9 don't — the manifest's stored-tag design (not
filename-derived) handled both without special-casing. Zero
filename-prefix mismatches against the `<pkg>_...` convention
`build-repo.sh`'s `classify_asset` expects. Spot-checked real downloaded
content (not just the 302) for a further 4 tools spanning different
ecosystems (`duckdb` C++, `zed`, `bun`, `neovim`) — all valid `.deb`s.

## What's NOT done

This is unreviewed, un-deployed, and deliberately left that way — going
live changes the base URI apt clients and the extrepo policy point at,
which is a real, hard-to-reverse, user-facing change (see step 4's
migration/sequencing notes). Specifically still open:

1. ~~Not deployed.~~ **Deployed**: `https://latest-debs-apt-redirector.ranjithraj.workers.dev`.
   Hit a real bug on first deploy that local `wrangler dev` never surfaced:
   every `fetch()` call (both the origin pass-through and the manifest
   lookup) failed with Cloudflare error 1042 — `*.workers.dev` is treated
   as one shared zone, and outbound `fetch()` from a Worker hosted there is
   restricted by default. Fixed with the `global_fetch_strictly_public`
   compatibility flag in `wrangler.jsonc`; confirmed working against real
   production data after redeploying (pass-through 200s on the real signing
   key, pool redirect correctly 502s — see item 2, not a bug). Local dev
   doesn't run under the real `workers.dev` zone, so this class of issue
   needs a real deploy to catch, not just `wrangler dev`.
2. **`ORIGIN_BASE`/`MANIFEST_URL` point at production `latest-debs.github.io`
   today**, which still means the manifest (`dists/pkg-repo-map.json`)
   doesn't exist there yet. The generation mechanism itself is confirmed
   working — a real, unmodified run of `scripts/build-repo.sh` via
   `scripts/run-in-debian.sh`'s own approach produced a correct
   `pkg-repo-map.json`, cross-checked tag-for-tag against live GitHub data
   — but that was against a scratch copy with a trimmed `tools.yaml`, not
   an actual production rebuild. `build-repo.sh` still needs to run for
   real (via CI, or `scripts/run-in-debian.sh` against the real
   `tools.yaml`) before the Worker's pool redirects resolve anything in
   production.
3. **Sequencing from step 4 isn't executed**: the extrepo-data update MR,
   the README manual-install snippet update, and keeping the old origin
   fully live (both `dists/` and `pool/`) through a transition window
   before retiring it.
4. **Coverage note, not a gap**: all 41 tracked tools / 749 real release
   assets were exercised (see the full-catalog run above) using a manifest
   built from live `releases/latest` data, but the test still ran against a
   *local* `pkg-repo-map.json` fixture, not the real
   `dists/pkg-repo-map.json` that only exists once item 2 (a production
   rebuild) has actually happened. Worth re-running this same check (it's
   now a cheap, repeatable script, not manual work) once that file is real,
   as a final pre-cutover gate.

## Local development

```sh
npm install
npm run dev -- \
  --var MANIFEST_URL:<url to a test pkg-repo-map.json> \
  --var ORIGIN_BASE:https://latest-debs.github.io/apt-repo/
```

## Deployment

Live at **`https://latest-debs-apt-redirector.ranjithraj.workers.dev`**.
No custom domain or paid Cloudflare plan required — `workers_dev: true` in
`wrangler.jsonc` gives the free `*.workers.dev` URL. This becomes the new
apt `sources.list` base URI once the migration in step 4 (extrepo-data MR,
README update, transition window) is actually carried out — deploying the
Worker doesn't change what any apt client points at by itself.

```sh
npm run dry-run   # wrangler deploy --dry-run — validates without publishing
npm run deploy    # redeploy after a code/config change
```

Run from `redirector/`, not the repo root — `wrangler` scaffolds a
different, unrelated Worker config if run from a directory with no
existing `wrangler.jsonc` (hit this once already; see git history).
