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

The Worker is deployed and serving; what remains is the migration of what
apt clients are *told* to point at. Items 1 and 2 below are done and kept
for the record; item 3 is the live one.

1. ~~Not deployed.~~ **Deployed**: `https://latest-debs.ranjithraj.workers.dev`
   (renamed once from `latest-debs-apt-redirector` — the old name was
   deleted, not left orphaned). Hit a real bug on first deploy that local
   `wrangler dev` never surfaced: every `fetch()` call (both the origin
   pass-through and the manifest lookup) failed with Cloudflare error 1042
   — `*.workers.dev` is treated as one shared zone, and outbound `fetch()`
   from a Worker hosted there is restricted by default. Fixed with the
   `global_fetch_strictly_public` compatibility flag. Local dev doesn't run
   under the real `workers.dev` zone, so this class of issue needs a real
   deploy to catch, not just `wrangler dev`.
2. ~~Production manifest doesn't exist yet.~~ **Resolved** — `build-repo.sh`
   has run for real in production (triggered via `workflow_dispatch`, not
   just the scheduled job) and `dists/pkg-repo-map.json` is live with all
   41 entries. Verified the full chain against real production data, not
   just the local fixture used for the full-catalog run below: pass-through
   resolves the real signing key, pool redirect resolves a real package to
   the correct GitHub Release URL, and a full download through the Worker
   produced a genuine, valid `.deb` (`ar t` confirmed).
3. **The extrepo-data MR is the last step, and it is now overdue rather
   than deliberately held.** The README/site manual-install snippets were
   already switched to the Worker, and `pool/` was already dropped from the
   GitHub Pages origin (it exceeded Pages' 1GB published-site limit) — so
   the "keep the old origin fully live through a transition window" part of
   step 4's sequencing did not actually happen. **Verified live 2026-09-04:**

   | Path | Old origin (`latest-debs.github.io/apt-repo/`) | Worker |
   |---|---|---|
   | `dists/trixie/Release` | 200 | 200 |
   | `dists/trixie/main/binary-amd64/Packages` | 200 (50 packages) | 200 |
   | `pool/trixie/*/*.deb` (6 sampled) | **404** | 200, valid `.deb` |
   | `pool/` index | **404** | — |

   Because `dists/` still resolves there, `apt update` succeeds and the
   packages appear in `apt search` — the failure only shows up at `apt
   install`, as a 404 on download. Upstream extrepo-data still publishes
   `URIs: https://latest-debs.github.io/apt-repo/` (confirmed against
   `repos/debian/latest-debs.yaml` on master), so **every user who installed
   via `extrepo enable latest-debs` is currently broken.**

   Interim mitigation is in place: README and the site both lead with the
   manual snippet and carry an explicit "don't use extrepo yet" notice. The
   actual fix is the MR below; the notices come out in the same change that
   lands it.

   ### Landing the extrepo-data MR

   `extrepo/latest-debs.yaml` in this repo is the finished replacement file —
   it already carries the Worker `URIs:` and the corrected per-suite
   `Architectures:` (upstream's copy is missing `armel` and `loong64`). It
   needs a Salsa account, so it can't be automated from here:

   ```sh
   # 1. Fork https://salsa.debian.org/extrepo-team/extrepo-data on Salsa, then:
   git clone git@salsa.debian.org:<you>/extrepo-data.git
   cd extrepo-data
   git checkout -b latest-debs-redirector-origin

   # 2. Drop in the staged file (this repo's copy is authoritative).
   cp <apt-repo>/extrepo/latest-debs.yaml repos/debian/latest-debs.yaml

   # 3. Sanity-check it the way upstream's generator will.
   git diff --stat
   python3 -c 'import yaml,sys; yaml.safe_load(open("repos/debian/latest-debs.yaml"))'

   git commit -am 'latest-debs: point at the redirector origin

   pool/ is no longer served from GitHub Pages (1GB published-site limit);
   the Cloudflare Worker is now the single origin serving both dists/ and
   pool/. Also adds armel and loong64, which the packages actually ship.'
   git push -u origin latest-debs-redirector-origin
   # 4. Open the MR against extrepo-data master.
   ```

   Keep the old origin's `dists/` published until the MR is merged *and* a
   release of `extrepo-data` carrying it has propagated — an apt client that
   has not refreshed its policy is still pointed at the old base URI, and a
   working `apt update` there is what keeps `apt search` honest while the
   install path is broken. Only retire it after that.

## Local development

```sh
npm install
npm run dev -- \
  --var MANIFEST_URL:<url to a test pkg-repo-map.json> \
  --var ORIGIN_BASE:https://latest-debs.github.io/apt-repo/
```

## Deployment

Live at **`https://latest-debs.ranjithraj.workers.dev`**.
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
