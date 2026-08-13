![latest-debs apt repository](.github/readme-header.png)

# latest-debs apt repository

Latest stable releases of developer tools, packaged for Debian and served
over `apt`.

- **Debian:** Bookworm (12), Trixie (13), Forky (14/testing), Sid (unstable)
- **Architectures:** amd64, arm64, armhf, ppc64el, s390x, riscv64 (plus i386 on bookworm/trixie)
- **Updates:** every ~6 hours, automatically

All packages are built from upstream releases using the
[debian-multiarch-builder](https://github.com/ranjithrajv/debian-multiarch-builder)
GitHub Action. Each tool's packaging lives in its own repo under this
organization.

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

To let it fully deploy, create a fine-grained PAT with **Administration:
write** and **Contents: write** on the `latest-debs` org (or a classic PAT with
`repo` + `workflow` + `admin:org` scopes) and store it as the
**`ORG_ADMIN_TOKEN`** secret in this repo. Once set, the workflow will:

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
scripts/add-package.sh      validate + scaffold + deploy + register tool
scripts/build-repo.sh       fetch releases + generate pool/ and dists/
scripts/sync-readme.sh      regenerate the package table in README.md
scripts/run-in-debian.sh    run build-repo.sh in a Debian container
scripts/sign-repo.sh        GPG-sign dists (run on a Debian machine)
extrepo/latest-debs.yaml    extrepo metadata (contributed upstream)
latest-debs.asc             public signing key
pool/                       downloaded .deb + source files (generated)
dists/                      apt indexes (generated)
```
