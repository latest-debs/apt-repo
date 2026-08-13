![latest-debs apt repository](.github/readme-header.png)

# latest-debs apt repository

Latest stable releases of developer tools, packaged for Debian and served
over `apt`.

- **Debian:** Bookworm (12), Trixie (13), Forky (14/testing), Sid (unstable)
- **Architectures:** amd64, arm64, armhf, ppc64el, s390x, riscv64 (plus i386 on bookworm/trixie)
- **Updates:** near-instant — publishing a release in a `*-debian` repo
  triggers an immediate rebuild via webhook, with a ~6h scheduled run as the
  fallback. Best-effort, no SLA (see
  [Support & expectations](#support--expectations-best-effort-no-sla))

All packages are built from upstream releases using the
[debian-multiarch-builder](https://github.com/ranjithrajv/debian-multiarch-builder)
GitHub Action. Each tool's packaging lives in its own repo under this
organization.

Every release is gated by **lintian** (Debian's package policy checker) and a
**smoke test** that runs the packaged binaries in a container and verifies
they report the expected version before the release is published — so the
channel only ever carries packages that both pass policy and actually run.

## Why this channel exists

An **auditable, signed, test-gated latest channel** — that's the differentiator.
It sits between two unsatisfying extremes: Debian's frozen cadence and ad-hoc
"download the tarball from GitHub" installs.

**vs. Debian stable** — Debian freezes versions for years; you wait for
backports or the next release. Here, the moment a `*-debian` repo publishes a
release, a webhook (`repository_dispatch`) fires an **immediate** apt-repo
rebuild — with a ~6h scheduled run as the catch-up backstop — so you get
current tools on a stable base, through the same `apt` you already trust.

**vs. ad-hoc release downloads** — a raw GitHub binary is trust-on-download:
no policy check, no run test, no signature chain, no record of what you got.
Every package in this channel instead carries:

- **Signed** — the apt indexes are GPG-signed on every rebuild
  (`scripts/sign-repo.sh`) and `apt` verifies them via `signed-by=`, so the
  metadata describing every package is authentic, not just the download.
- **Test-gated** — lintian (Debian's packaging policy checker) plus a smoke
  test that actually runs the packaged binaries in a container and confirms
  they report the expected version. Nothing is released that fails policy or
  doesn't run.
- **Auditable** — each package carries a provenance pin (upstream release
  identity + SHA-256, cross-checked against the vendor's published checksum at
  vet time), every build lands as a *draft* that a maintainer reviews before
  promotion, and the whole chain — packaging repos, builder action, rebuild
  pipeline — runs in public repos with full history (see
  [Supply chain & provenance](#supply-chain--provenance)).

That combination is what ad-hoc downloads can't offer (no signing, no policy,
no audit trail) and what Debian's cadence can't offer (currency).

## For project maintainers: package your tool as a signed `.deb`

Have a project that publishes a Linux binary on GitHub? We can package it for
Debian the same way the tools above are — signed, test-gated, provenance-pinned,
and kept current automatically. The `<tool>-debian` repo is yours: public,
forkable, and maintained via the feature channel (a template change rolls out
to every package repo in one operation, so improvements land everywhere at
once).

What you get, concretely:

- A public packaging repo scaffolded from one template, with CI and full history.
- Auto-watch: new upstream releases are built automatically, no per-version work.
- All four Debian suites × every architecture your release actually publishes
  a Linux binary for (verified precisely at vet time), plus source packages.
- GPG-signed apt indexes, lintian + smoke-test gates, a vet-time SHA-256
  provenance pin, and automated license/SPDX + asset pre-checks at intake.
- Near-instant updates via webhook-triggered rebuilds.

It's volunteer-run and best-effort (no SLA), but the packaging is yours to
fork and take anywhere. See **[SERVICE.md](SERVICE.md)** for the full pitch,
the offer, and how to get started (or just open a
[package request](https://github.com/latest-debs/apt-repo/issues/new?template=package-request.yml)).

## Support & expectations (best-effort, no SLA)

This is a volunteer-run project, not a commercial service. Everything runs on
free GitHub Actions and manual review, so treat the channel as **best-effort
with no SLA**:

- **Rebuild cadence.** Publishing a release normally rebuilds the apt index
  within minutes (a webhook from the `*-debian` repo triggers it). If that
  webhook is missed — lost dispatch, a missing `TRIGGER_TOKEN`, a runner
  outage, or GitHub deferring scheduled/dispatch events under load — the ~6h
  scheduled run is the guaranteed catch-up. A freshly published upstream
  release can therefore appear within minutes or take longer, and if an
  upstream archive becomes unavailable, that version may be skipped entirely.
  Don't build a pipeline that depends on a package appearing by a deadline.
- **Draft release promotion.** Packages are never auto-published. Every build
  lands as a *draft* GitHub release that a maintainer reviews and publishes by
  hand (see [Supply chain & provenance](#supply-chain--provenance)). That
  human gate is deliberate — it keeps tampered or broken releases out of the
  channel — but it means promotion lags the build, and if a maintainer is
  away, newer versions wait.
- **Upstream dependency.** We repackage upstream GitHub releases as they
  publish them. If an upstream changes its release layout, removes old
  archives, or goes away, the corresponding tool silently stops updating until
  someone fixes the packaging.

What we do guarantee: the channel stays internally consistent. Indexes are
always GPG-signed, every package is lintian-checked, smoke-tested, and
checksum-verified before publication, and nothing ships that a human hasn't
reviewed. Rely on it for convenience — not for security-critical or
time-critical patch delivery.

## Install

Via [extrepo](https://salsa.debian.org/extrepo-team/extrepo) (Debian):

```sh
sudo extrepo enable latest-debs
sudo apt update
sudo apt install uv eza lazygit
```

Manually:

```sh
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://raw.githubusercontent.com/latest-debs/apt-repo/main/latest-debs.asc | sudo gpg --dearmor --yes -o /etc/apt/keyrings/latest-debs.gpg
echo "deb [signed-by=/etc/apt/keyrings/latest-debs.gpg] https://latest-debs.github.io/apt-repo/ $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/latest-debs.list
sudo apt update
```

> **Note:** The repository indexes are GPG-signed (`scripts/sign-repo.sh` runs
> automatically on every rebuild). `apt` verifies signatures against the key
> imported above via `signed-by=`.

## Adding or updating a tool

- **Request a package:** open a
  [package request](https://github.com/latest-debs/apt-repo/issues/new?template=package-request.yml)
  — tool name, upstream URL, and license is all we need. Valid requests are
  validated and scaffolded automatically by the
  [`Process package request`](.github/workflows/package-request.yml) workflow;
  open requests are tracked under the
  [`package-request` label](https://github.com/latest-debs/apt-repo/labels/package-request).
- **Do it yourself:**
  1. Add an entry to `tools.yaml` pointing at the tool's package repo
     (e.g. `https://github.com/latest-debs/uv-debian`).
  2. The scheduled workflow picks it up automatically on the next run.

### Maintainers: automating a package request

The [`Process package request`](.github/workflows/package-request.yml) workflow
runs on every `package-request` issue. With no extra setup it validates the
request (upstream exists, publishes a Linux `.tar.gz`/`.tgz`/`.zip` release
asset) and leaves a comment on the issue.

To let it fully deploy, create a fine-grained PAT restricted to the
`latest-debs` org with **Administration: write**, **Contents: write**, and
**Workflows: write** (never a classic PAT with `admin:org`), set a short
expiry, and store it as the **`ORG_ADMIN_TOKEN`** secret in this repo. It is
only ever used to create org repos and dispatch their first build; everything
else in the workflow (issue comments, `tools.yaml` pushes) runs on the
repo-scoped `GITHUB_TOKEN`. Rotate it periodically. Once set, the workflow
will:

1. scaffold a `<tool>-debian` repo from
   [`templates/package-scaffold`](templates/package-scaffold),
2. create and push it, dispatch the first auto build,
3. register the package in `tools.yaml`, and
4. comment on the issue.

All package repos use the auto-watching workflow: a scheduled job compares the
latest upstream release against what's already built and rebuilds new versions
automatically (see `scripts/detect-version.sh` in any `*-debian` repo).

When a `*-debian` release is **published**, its
[`notify-apt-repo` workflow](templates/package-scaffold/.github/workflows/notify-apt-repo.yml)
dispatches an immediate apt-repo rebuild via `repository_dispatch` — so a new
package version lands in the apt index within minutes, not at the next ~6h
schedule. This needs a **`TRIGGER_TOKEN`** Actions secret on the package repo:
a fine-grained PAT scoped to *apt-repo only* with **Contents: write** (the
minimum for `repository_dispatch`). New repos get it copied at deploy time
(best-effort); run `scripts/set-trigger-secret.sh` to backfill existing repos
and to rotate. A repo without the secret falls back to the scheduled rebuild —
the webhook is an optimization, never a correctness dependency.

Package repo releases must be named so the suite is embedded, e.g.:

```
uv_0.12.3-1.bookworm_amd64.deb
uv_0.12.3-1.bookworm.dsc
uv_0.12.3-1.trixie_amd64.deb
```

See [tools.yaml](tools.yaml) and `scripts/build-repo.sh`.

### Shipping a template change (the feature channel)

`templates/package-scaffold` is the single source of truth for every
`*-debian` repo's packaging workflow. To ship a change — a new
[debian-multiarch-builder](https://github.com/ranjithrajv/debian-multiarch-builder)
version pin, a glob fix, a smoke-test improvement — edit the template,
commit it, then run:

```sh
scripts/rollout-autowatch.sh --dry-run   # preview: what would change per repo
scripts/rollout-autowatch.sh             # real run: 1 commit pushed per repo
```

It regenerates `.github/workflows/release.yml`, `.github/workflows/notify-apt-repo.yml`,
and `.github/scripts/detect-version.sh` in every repo (placeholders
substituted from each repo's `package.yaml`) and pushes one commit per repo
to `main`. Idempotent: repos already at the template are skipped. Use
`--repo owner/repo` to target a single repo. `README.md` is intentionally
not rolled out — child READMEs carry per-repo customizations.

## Supply chain & provenance

The pipeline defends against upstream supply-chain attacks with two layers:

- **Draft-before-publish** — every `*-debian` build produces a *draft* GitHub
  release. Only a human publishing the draft makes the packages visible to
  the apt repo's rebuild, so nothing we ship was ever auto-published.
- **Vet-time provenance pin** — when a package request is vetted
  (`scripts/vet-release.sh`, via `add-package.sh scaffold`), the upstream
  asset is downloaded, its SHA-256 is cross-checked against the release's
  published checksum file, and the release identity plus digest are captured
  in `.github/release-metadata.json` inside the scaffolded repo. The
  [debian-multiarch-builder](https://github.com/ranjithrajv/debian-multiarch-builder)
  re-verifies the exact bytes it downloads against that pin when building the
  vetted version, so a release altered *after* vetting fails the build
  instead of being silently packaged. Releases that appear later (via the
  auto-watch) have no pin yet, so they are verified against the release's own
  checksum file and still gated by draft-before-publish until a maintainer
  vets them.

Access is scoped to the minimum: repo-scoped `GITHUB_TOKEN` wherever possible
(issue handling, `tools.yaml`), and a fine-grained, org-restricted
`ORG_ADMIN_TOKEN` only for creating org repos and dispatching their first
build. GitHub API calls are authenticated everywhere to avoid the shared
60/hour anonymous rate limit silently starving every fetch.

## Packages

<!-- packages:start -->

| Package | Install | Upstream |
|---------|---------|----------|
| `uv` | `apt install uv` | [astral-sh/uv](https://github.com/astral-sh/uv) |
| `vite-plus` | `apt install vite-plus` | [voidzero-dev/vite-plus](https://github.com/voidzero-dev/vite-plus) |
| `eza` | `apt install eza` | [eza-community/eza](https://github.com/eza-community/eza) |
| `lazygit` | `apt install lazygit` | [jesseduffield/lazygit](https://github.com/jesseduffield/lazygit) |
| `ruff` | `apt install ruff` | [astral-sh/ruff](https://github.com/astral-sh/ruff) |
| `bun` | `apt install bun` | [oven-sh/bun](https://github.com/oven-sh/bun) |
| `deno` | `apt install deno` | [denoland/deno](https://github.com/denoland/deno) |
| `duckdb` | `apt install duckdb` | [duckdb/duckdb](https://github.com/duckdb/duckdb) |
| `lazydocker` | `apt install lazydocker` | [jesseduffield/lazydocker](https://github.com/jesseduffield/lazydocker) |
| `ripgrep` | `apt install ripgrep` | [BurntSushi/ripgrep](https://github.com/BurntSushi/ripgrep) |
| `fd` | `apt install fd-find` | [sharkdp/fd](https://github.com/sharkdp/fd) |
| `fzf` | `apt install fzf` | [junegunn/fzf](https://github.com/junegunn/fzf) |
| `starship` | `apt install starship` | [starship/starship](https://github.com/starship/starship) |
| `just` | `apt install just` | [casey/just](https://github.com/casey/just) |
| `hyperfine` | `apt install hyperfine` | [sharkdp/hyperfine](https://github.com/sharkdp/hyperfine) |
| `k9s` | `apt install k9s` | [derailed/k9s](https://github.com/derailed/k9s) |
| `atuin` | `apt install atuin` | [atuinsh/atuin](https://github.com/atuinsh/atuin) |
| `xh` | `apt install xh` | [ducaale/xh](https://github.com/ducaale/xh) |
| `yq-go` | `apt install yq-go` | [mikefarah/yq](https://github.com/mikefarah/yq) |
| `du-dust` | `apt install du-dust` | [bootandy/dust](https://github.com/bootandy/dust) |
| `procs` | `apt install procs` | [dalance/procs](https://github.com/dalance/procs) |
| `bottom` | `apt install bottom` | [ClementTsang/bottom](https://github.com/ClementTsang/bottom) |
| `bat` | `apt install bat` | [sharkdp/bat](https://github.com/sharkdp/bat) |
| `zoxide` | `apt install zoxide` | [ajeetdsouza/zoxide](https://github.com/ajeetdsouza/zoxide) |
| `git-delta` | `apt install git-delta` | [dandavison/delta](https://github.com/dandavison/delta) |
| `jj` | `apt install jj` | [jj-vcs/jj](https://github.com/jj-vcs/jj) |
| `gitui` | `apt install gitui` | [extrawurst/gitui](https://github.com/extrawurst/gitui) |

<!-- packages:end -->

## Layout

```
tools.yaml                  registry of tracked tools
templates/package-scaffold  template for new <tool>-debian repos
scripts/add-package.sh      validate + vet (checksum) + scaffold + deploy + register tool
scripts/vet-release.sh      vet-time checksum verification + release metadata capture
scripts/build-repo.sh       fetch releases + generate pool/ and dists/
scripts/sync-readme.sh      regenerate the package table in README.md
scripts/run-in-debian.sh    run build-repo.sh in a Debian container
scripts/sign-repo.sh        GPG-sign dists (run on a Debian machine)
scripts/set-trigger-secret.sh  backfill TRIGGER_TOKEN onto *-debian repos
scripts/rollout-autowatch.sh   one-command template rollout to all *-debian repos
extrepo/latest-debs.yaml    extrepo metadata (contributed upstream)
latest-debs.asc             public signing key
pool/                       downloaded .deb + source files (generated)
dists/                      apt indexes (generated)
```
