# Upstream-`.deb` handoff candidates (generated 5 Sep 2026)

These tracked tools' **latest upstream releases already ship `.deb`
assets**. Under the upstream-parity policy
([README](README.md#upstream-parity--when-we-dont-start)), each is a
graduation candidate: `reason: own-deb` in
[`graduated.json`](graduated.json), dropped from `tools.yaml`, users
pointed upstream.

Scanned today from each upstream's latest GitHub release. **Human-gated:
nothing here graduates without per-tool review** — the two flags in the
README policy apply, and one weighs heavier here than anywhere else in the
matrix:

> **The route trade-off.** A Debian-parity handoff never costs the user a
> route: Debian has an apt index, so `apt install` keeps working. An
> upstream `.deb` attachment is *not* a channel — it's a manual download,
> and handing off ends our `apt upgrade` for that tool. Every entry below
> should be read as "is a signed, smoke-tested, auto-updated copy worth
> less than one signed key fewer in the user's keyring?" The honest default
> for most of this list is probably: keep the package, note it as a
> handoff-waiting-on-an-upstream-channel. The ledger exists so that the
> moment upstream runs a real apt index, the step-aside is one dated entry.

## Own apt repo already (these are `reason: own-repo` candidates)

| Tool | Upstream | Channel | Verdict |
|---|---|---|---|
| trivy | aquasecurity/trivy | [trivy.dev apt repo](https://trivy.dev/latest/docs/installation/) | **Graduate** — own signed repo, first `graduated.json` entry. |
| gh | cli/cli | [cli/cli's own apt repo](https://github.com/cli/cli/blob/trunk/docs/install_linux.md) | **Confirm & graduate** — official instructions point at their signed repo. |

## Upstream ships `.deb`s, no apt index (`reason: own-deb` candidates)

Per the policy flags, each needs an arch-coverage check and an
installability judgement before an entry lands:

| Tool | Upstream | Latest tag | `.deb`s in release |
|---|---|---|---|
| bat | sharkdp/bat | v0.26.1 | 8 |
| bottom | ClementTsang/bottom | 0.14.9 | 6 |
| du-dust | bootandy/dust | v1.2.5 | 2 |
| fastfetch | fastfetch-cli/fastfetch | 2.68.1 | 10 |
| fd | sharkdp/fd | v10.5.0 | 8 |
| fzf | junegunn/fzf | v0.74.3 | 9 |
| git-delta | dandavison/delta | 0.19.2 | 5 |
| gum | charmbracelet/gum | v2.0.0 | 5 |
| helix | helix-editor/helix | 25.07.1 | 1 |
| hexyl | sharkdp/hexyl | v0.17.0 | 7 |
| hyperfine | sharkdp/hyperfine | v1.20.0 | 7 |
| k9s | derailed/k9s | v0.51.0 | 5 |
| ripgrep | BurntSushi/ripgrep | 15.2.0 | 1 |
| watchexec | watchexec/watchexec | v2.7.1 | 9 |
| zoxide | ajeetdsouza/zoxide | v0.10.0 | 5 |

## Where the list came from

Latest-release asset scan across every `github_repo` in the 46
`package.yaml` files (release API, `.deb$` suffix match), 5 Sep 2026.
Refresh before each review round — release layouts change.

## Process for each handoff (when it's approved)

1. Append the entry to `graduated.json` — `package`, date (UTC),
   `reason: own-deb` (or `own-repo`), `destination` (upstream release page
   or apt repo), one-line `note` (arch coverage, channel reality).
2. Drop the tool from `tools.yaml` in the same PR.
3. Archive or mark the tool's `*-debian` repo; keep its releases for
   provenance.
4. The coverage table, staleness report, and status page pick up the
   removal automatically; the ledger entry is what users land on.
