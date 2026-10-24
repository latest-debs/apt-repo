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
   needs a Salsa account; with `glab auth login --hostname salsa.debian.org`
   done, the whole sequence is:

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

   **Deploy the Worker before opening the MR.** `tools/validate-repo` in
   extrepo-data does not just lint the YAML — it fetches
   `<URIs>/dists/<suite>/InRelease` from the *live* origin and fails the
   whole repository if it 404s. It builds that URL by joining the base URI
   (which ends in `/`) with `/dists/...`, so it requests `//dists/...`, and
   the Worker used to 404 on the doubled slash: `proxyToOrigin` stripped
   only one leading slash, leaving an absolute path that `new URL` resolved
   against the origin root and so dropped the `/apt-repo/` prefix. The old
   GitHub Pages origin normalised `//` server-side, which is why upstream's
   copy validates today and ours did not. Fixed in `src/worker.js`
   (`normalizePath` / `originUrlFor`, covered by `npm test`).

   **Done, 2026-09-05.** Fix deployed, and `tools/validate-repo` now passes
   against the staged file for all four suites: `InRelease` retrieved and
   its signature verified against `9329C48E...518AB96A` on each, and every
   per-architecture `Packages` found, `loong64` included. The branch
   `latest-debs-redirector-origin` is pushed to the `ranjithraj/extrepo-data`
   fork, branched off `upstream/master` rather than the fork's stale master,
   and opened as
   [extrepo-data!573](https://salsa.debian.org/extrepo-team/extrepo-data/-/merge_requests/573).

   When it merges, drop the "extrepo is currently broken" notices — they
   are in three places: the org profile (`.github/profile/README.md`),
   `apt-repo/README.md`, and the site (`latest-debs.github.io/index.html`).

   **Keep the staged file a minimal delta against upstream's copy.** It is a
   drop-in replacement for `repos/debian/latest-debs.yaml`, so anything
   added to it becomes part of the MR diff. Rebuild it from
   `git show upstream/master:repos/debian/latest-debs.yaml` and re-apply
   only the substantive changes rather than editing it freehand — the first
   version of !573 carried 30 changed lines, of which 21 were commentary
   that only made the review larger.

   **Why no Ubuntu codenames are listed.** extrepo-data is Debian-only by
   construction: its generator globs `repos/debian/*.yaml` into a hardcoded
   `debian` dist and validates every `suites:` entry against
   `Debian::DistroInfo` (`tools/lib/ExtRepoData.pm` — `croak "Unknown
   Debian release"`), so an Ubuntu codename fails the upstream publish
   pipeline rather than degrading gracefully. Ubuntu users are still
   served: the `extrepo` package reads dist/version from a static
   `/etc/extrepo/config.yaml`, not `os-release`, and Ubuntu's universe
   builds ship `dist: debian` with a Debian codename (jammy's 0.9 →
   bookworm; noble's 0.13 and questing's 0.15 → trixie), so
   `extrepo enable latest-debs` on Ubuntu resolves one of our Debian
   suites. Our own Ubuntu aliases live in `suites.json` and are served over
   apt directly; they are not expressible here. (Jammy is the exception
   documented in `apt-repo/README.md` — its pinned `bookworm` has newer
   glibc than jammy, so jammy users want the manual snippet.)

   **`bullseye` is deliberately not in the MR.** We still serve it —
   `dists/bullseye/Release` is live and signed for
   `amd64 arm64 armhf i386 loong64 ppc64el riscv64 s390x` (no `armel`,
   unlike bookworm/trixie), `suites.json` tracks it, and `jammy` is an alias
   of it — so `extrepo enable latest-debs` on a Debian 11 box enables
   nothing today even though the packages exist. It was left out because
   bullseye's LTS window ended 2026-08-31 and listing a just-EOL suite in
   Debian's own metadata invites an objection that would stall the urgent
   URI fix behind a policy argument. Two follow-ups this leaves open:

   - Decide whether to add bullseye (with a `suite-bullseye-Architectures:`
     line dropping `armel`) or retire it everywhere. Retiring it also ends
     Ubuntu 22.04 support — jammy is an alias of bullseye and the only suite
     with old-enough glibc (2.31, against jammy's 2.35).
   - `SERVICE.md` tells prospective upstreams that "a suite retires
     automatically once its Debian LTS window ends." There is no such
     implementation anywhere in `scripts/` or `.github/`, and bullseye going
     EOL is the first case that would have exercised it. Either build it or
     correct the claim.

   Keep the old origin's `dists/` published until the MR is merged *and* a
   release of `extrepo-data` carrying it has propagated — an apt client that
   has not refreshed its policy is still pointed at the old base URI, and a
   working `apt update` there is what keeps `apt search` honest while the
   install path is broken. Only retire it after that.

## Usage analytics

`MARKET-ANALYSIS.md`'s blocking finding is that 51,760 release-asset
downloads cannot be told apart from crawlers, and that nothing anywhere
records *which suite or architecture* is actually pulled. GitHub's asset
counter only ever sees the 302 target. This Worker sees the real apt
request, so it is the only place that breakdown can come from.

Every request writes one Analytics Engine data point (binding `AE`, dataset
`latest_debs_requests`), in `ctx.waitUntil` so a download never waits on a
metric, and inside a `try`/`catch` so instrumentation can never break
package serving:

| Field | Contents |
|---|---|
| `blob1` | `pool` (a package download), `index` (a `dists/` fetch), or `other` |
| `blob2` | suite — `trixie`, `sid`, … (also `index1`, the sampling key) |
| `blob3` | architecture — `amd64`, `riscv64`, `source`, … |
| `blob4` | package name, for `pool` hits |
| `blob5` | country (`request.cf.country`) |
| `blob6` | daily-rotating salted digest of IP + User-Agent |
| `double1` | constant `1`, so `SUM` reads as a hit count under sampling |
| `double2` | response status |

**Cost.** Free plan covers 100,000 data points written and 10,000 read
queries per day, and Cloudflare does not currently bill for Analytics
Engine at all — so this stays inside `PLATFORM-EVALUATION.md`'s founding
zero-cost constraint. At present traffic the daily write cap is not close;
it is worth re-checking if a suite ever goes viral, since the cap is per
day and silently drops writes past it. Retention is 90 days, so anything
meant to be a long-run series has to be rolled up and stored elsewhere
before it ages out.

**Set the salt before trusting `blob6`.** It is a SHA-256 of
`<UTC date> <CLIENT_SALT> <IP> <User-Agent>`, truncated to 8 bytes and
rotated daily. Without the secret, only the date salts it, and the whole
IPv4 space is cheap to brute-force against a known digest:

```sh
wrangler secret put CLIENT_SALT   # any long random string, rotate freely
```

Rotating the salt only resets distinct-client continuity across the
rotation; it costs nothing else.

**Querying.** Analytics Engine has no dashboard — use the SQL API with an
account token holding *Account Analytics: Read*:

```sh
curl -s "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/analytics_engine/sql" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -d "SELECT blob2 AS suite, blob3 AS arch, SUM(_sample_interval * double1) AS hits
      FROM latest_debs_requests
      WHERE timestamp > NOW() - INTERVAL '7' DAY AND blob1 = 'pool'
      GROUP BY suite, arch ORDER BY hits DESC"
```

The number that settles positioning — is this project's real audience the
exotic-arch fleets its differentiation claims? — is that query's `arch`
column. Weekly distinct clients:

```sh
... -d "SELECT COUNT(DISTINCT blob6) AS clients
        FROM latest_debs_requests
        WHERE timestamp > NOW() - INTERVAL '7' DAY"
```

Read that as an upper bound on humans and a lower bound on machines: a NAT
'd fleet collapses to one digest, and a client that changes User-Agent
between `apt update` and `apt install` counts twice.

## External liveness watchdog

Every other alarm this project has — `rebuild.yml`, `staleness.yml`,
`report-workflow-failure.sh` — runs inside the same GitHub org as the thing
it watches, so they all go dark together. And a green pipeline is not the
same claim as a healthy archive: `build-repo.sh` can publish a suite whose
`Filename:` fields 302 to release assets upstream has since deleted, and
every `apt install` fails while `apt update` and CI stay green.

`scheduled()` closes that gap. It runs on Cloudflare's cron (a different
account, a different platform) every 6 hours and checks the published
archive the way apt does:

1. the origin's `dists/<suite>/Release` exists and was stamped inside the
   48h window — a silently stopped rebuild shows up here;
2. this Worker still serves it end to end, requested as `//dists/...`, the
   double-slash form apt and extrepo actually send (that path 404'd in
   production once already);
3. the first `Filename:` in the index really is downloadable — our 302
   resolves *and* the GitHub asset behind it still exists.

Failures open one `origin-unhealthy` tracking issue on `apt-repo`, and a
recovery closes it. That label is deliberately not `pipeline-failure`: that
issue is shared by the two in-org workflows and its all-clear is computed
from their run status, which says nothing about whether the archive serves.

Filing findings needs a token:

```sh
wrangler secret put ALERT_TOKEN   # fine-grained PAT, apt-repo only,
                                  # Issues: read and write
```

Without it the check still runs and logs its verdict; it just cannot open
the issue. `WATCHDOG_SUITE`, `WATCHDOG_ARCH` and `WATCHDOG_STALE_HOURS`
override the defaults (`trixie`, `amd64`, 48).

Run the checks against live production without waiting for the cron:

```sh
node -e 'import("./src/worker.js").then(async (m) =>
  console.log(await m.checkOrigin({
    ORIGIN_BASE: "https://latest-debs.github.io/apt-repo/",
    PUBLIC_BASE: "https://latest-debs.ranjithraj.workers.dev",
  })))'
```

`test-watchdog.mjs` covers each failure mode against a stubbed fetch.

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
