![latest-debs apt repository](.github/readme-header.png)

# latest-debs apt repository

Latest stable releases of developer tools, packaged for Debian and served
over `apt`.

- **Debian:** Bookworm (12), Trixie (13), Forky (14/testing), Sid (unstable)
- **Architectures:** amd64, arm64, armhf, ppc64el, s390x, riscv64 (plus i386 on bookworm/trixie)
- **Updates:** best-effort, roughly every 6 hours — no SLA (see
  [Support & expectations](#support--expectations-best-effort-no-sla))

All packages are built from upstream releases using the
[debian-multiarch-builder](https://github.com/ranjithrajv/debian-multiarch-builder)
GitHub Action. Each tool's packaging lives in its own repo under this
organization.

Every release is gated by **lintian** (Debian's package policy checker) and a
**smoke test** that runs the packaged binaries in a container and verifies
they report the expected version before the release is published — so the
channel only ever carries packages that both pass policy and actually run.

## Why "latest" is different from Debian's cadence

Debian stable freezes versions for years between releases; this channel
repackages upstream GitHub releases on a best-effort cadence — typically
within hours, but with no SLA (see below) — so you get current tools on a
stable base without waiting for the next Debian release.

## Support & expectations (best-effort, no SLA)

This is a volunteer-run project, not a commercial service. Everything runs on
free GitHub Actions and manual review, so treat the channel as **best-effort
with no SLA**:

- **Rebuild cadence.** The apt index is regenerated on a schedule (roughly
  every 6 hours) and new tool versions are picked up on the next run. GitHub
  can defer or fail scheduled workflows under load, runners occasionally go
  offline, and API rate limits bite. A freshly published upstream release can
  therefore appear within minutes or take much longer — and if an upstream
  archive becomes unavailable, that version may be skipped entirely. Don't
  build a pipeline that depends on a package appearing by a deadline.
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

Package repo releases must be named so the suite is embedded, e.g.:

```
uv_0.12.3-1.bookworm_amd64.deb
uv_0.12.3-1.bookworm.dsc
uv_0.12.3-1.trixie_amd64.deb
```

See [tools.yaml](tools.yaml) and `scripts/build-repo.sh`.

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
extrepo/latest-debs.yaml    extrepo metadata (contributed upstream)
latest-debs.asc             public signing key
pool/                       downloaded .deb + source files (generated)
dists/                      apt indexes (generated)
```
