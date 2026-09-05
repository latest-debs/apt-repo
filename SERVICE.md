# Your tool, packaged and maintained as a signed `.deb`

> We package your project as a properly-signed, test-gated Debian package,
> keep it current automatically on every Debian release, and let your users
> `apt install` it — while you keep doing what you do.

## The problem

Users on Debian today have two unsatisfying options for getting your tool:

- **Debian stable's cadence** — if your tool is packaged at all, it is frozen
  at an old version until the next Debian release (or forever, for niche
  tools that never get packaged).
- **Raw GitHub tarballs** — trust-on-download: no signature, no policy check,
  no audit trail, no update mechanism, no source package.

This channel sits between those: **current, signed, gated, and maintained** —
and it is a service, not a one-off packaging job.

## What a project gets

Everything here is real and running today in the
[latest-debs](https://github.com/latest-debs) organization.

### One packaging repo per tool

A public `<tool>-debian` repo is scaffolded from a single template, with full
git history and a CI pipeline — not a script on someone's laptop. The repo is
yours: public, forkable, and under your control.

### Auto-watch

A scheduled job compares your latest upstream release against what is already
built and rebuilds new versions automatically. You ship a tag; we ship a
`.deb`.

### Real coverage

- **All five Debian suites** — Trixie and Bookworm carry essentially the full
  catalogue (61 and 59 of 61); Forky (51), Sid (49), and Bullseye (12) trail
  where an upstream's older-build constraints or the suite's toolchain make a
  build unreliable. Every suite's exact count, per architecture, is published
  on the [status page](https://latest-debs.github.io/status.html) — generated
  from the archive, not asserted. A suite retires automatically once its
  Debian LTS window ends.
- **Native Ubuntu builds** — Noble (24.04 LTS) and Resolute (26.04 LTS) are
  built in Ubuntu containers, not copied from Debian: correct dependencies,
  correct suite metadata, and an install path that works on the two distros
  most of your users actually run. Jammy (22.04 LTS) carries a smaller
  catalogue (13 of 61 — its old toolchain rules out several modern builds);
  the [status page](https://latest-debs.github.io/status.html) shows exactly
  which. (Questing, 25.10, is served from the Trixie build until its short
  support window is worth its own build.)
- **Every architecture you actually publish a Linux binary for** — amd64,
  arm64, armhf, i386, armel, loong64, ppc64el, riscv64, s390x, and we verify
  exactly which ones your release covers at vet time rather than assuming
  "all".
- **Source packages too** — so `apt-get source` works, not just `apt install`.

### A supply-chain story you can point to

- **Signed** — apt indexes are GPG-signed on every rebuild; `apt` verifies
  them via `signed-by=`.
- **Gated** — lintian (Debian's packaging policy checker) plus a smoke test
  that runs the packaged binary in a container and confirms it reports the
  expected version. Nothing ships that fails either gate.
- **Provenance-pinned** — at vet time the upstream asset is downloaded and its
  SHA-256 is cross-checked against the checksum file the project publishes.
  The builder re-verifies those exact bytes on every build, so a release
  altered *after* vetting fails the build instead of silently shipping.
- **Pre-checked at intake** — an automated license/SPDX scan compares the
  artifact's actual license content against the declared SPDX identifier
  (dual-licenses handled), validates the asset is a real runnable binary, and
  maps the release's assets to the precise set of Debian architectures it
  covers.
- **Attested** — every release publishes a Sigstore-signed SLSA
  build-provenance attestation and a signed SPDX SBOM, bound to the artifact
  digests. Your users can verify a package came from your release, built by
  the workflow it claims, with `gh attestation verify` — no trust in us
  required.
- **Human gate where it matters** — builds land as drafts that a maintainer
  reviews; nothing is auto-published past review.

### Near-instant updates

Publishing a release triggers an immediate apt-repo rebuild via webhook, with
a scheduled fallback — so users see new versions in minutes, not at the next
Debian release.

## Already publishing .debs on GitHub Releases?

Then your users who want `apt` are downloading a bare asset by hand: no
signature on the index, no `apt update`, no dependency metadata, no source
package, no policy check — and often only one or two architectures. Your
release page says "download this file and `dpkg -i` it".

latest-debs takes the same upstream binaries you already build and serves
them as what they want to be: a signed apt repository with native builds for
five Debian suites and three Ubuntu LTS/interim suites, lintian-gated,
smoke-tested, provenance-pinned, and attested. You keep building exactly
what you build today; your users get `apt install`, `apt upgrade`, and
`apt-get source`.

This is also our graduation path: if you later run your own apt repository,
we record it in `graduated.json`, stop publishing our copy for the suites
you cover, and point your users at yours. Replacing us is a feature, not a
failure.

## Why this is a product, not a packaging job

The key is the **feature channel**: every package repo is generated from one
template, and `scripts/rollout-autowatch.sh` ships a template change to
*every* tool repo with one idempotent command — one commit per repo, skipped
if already current. That means:

- The pipeline improves **once**, and every packaged tool improves with it.
  New builder versions, new smoke tests, new provenance checks — rolled out
  fleet-wide in a single operation.
- Onboarding a new tool is an **issue → automated validation → scaffold →
  vet → pre-checks → deploy → build → register** flow already run by a
  workflow. Adding a tool is a form, not a project.
- It scales by **construction**: packaging 5 tools costs the same maintenance
  as packaging 50, because there is no per-tool pipeline to babysit.

## The offer

For projects that publish a Linux binary (`.tar.gz`, `.tgz`, `.tar.xz`, or
`.zip`) on GitHub:

1. We scaffold your `<tool>-debian` repo from the template.
2. Vet time runs the checksum pin + license/SPDX scan + asset validation +
   architecture-coverage check, producing a reviewable report of exactly what
   is being shipped and on which architectures.
3. You (or your maintainers) review drafts; approved builds land in the
   signed apt repository.
4. Updates flow automatically from your release tags; pipeline improvements
   flow automatically from the feature channel.

**Your cost:** none — volunteer-run, best-effort, no SLA, and the packaging is
yours (the `<tool>-debian` repo is public and forkable).

**Your win:** `apt install yourtool` on every Debian, always current, with a
signing and provenance story a tarball can't match.

## We're complementary to upstream, not competing with it

This channel exists to fill a gap, not to become a permanent third party
between you and your users. Two things follow from that:

- **If you ship your own official apt repo, we hand off cleanly.** Tell us
  and we'll point the `<tool>-debian` repo and its README at your channel,
  archive it, and drop the entry from `tools.yaml` in the same PR — no
  negotiation, no lingering "which one is canonical" confusion for users. We'd
  rather see you running your own signed repo than keep packaging in your
  place. The same PR appends the hand-off to
  [`graduated.json`](graduated.json), which is published on the
  [status dashboard](https://latest-debs.github.io/status.html): a tool
  leaving because the gap it filled has closed is the outcome this channel
  is aiming for, so it gets counted as one rather than quietly disappearing —
  and anyone who goes looking for the removed package finds where it went.
- **If any live Debian suite already carries your latest release, we don't
  duplicate it.** A tool with a Debian Developer upstream (or an active
  Debian maintainer) often lands in unstable within days of a release —
  sometimes reaching trixie or even bookworm too — at which point that suite
  already offers current + Debian's own QA, which is strictly more than we
  can offer. New requests already at parity anywhere aren't scaffolded;
  existing packages that reach parity get flagged for retirement. We point
  users at that suite instead — directly if it's what they already run,
  pinned if it isn't — rather than running a second, lower-trust copy of
  what Debian already ships. See
  [Debian parity](README.md#debian-parity--when-we-step-aside).
- **Prefer to run this yourself from day one?** The pipeline packaging every
  tool here is just
  [debian-multiarch-builder](https://github.com/ranjithrajv/debian-multiarch-builder),
  a free, public, reusable GitHub Action — the same one your `<tool>-debian`
  repo would use if we did it. Point it at your release workflow and it turns
  an upstream binary release into signed, multi-arch `.deb`s in one run: no
  `debhelper` rules to write, no cross-arch build matrix to maintain by hand.
  Fast to adopt, and entirely yours to operate — we're happy to help you stand
  it up even if you never touch latest-debs itself.

## One more ask: link us from your install docs

Once your package is live, the highest-leverage thing you can do for your
Debian users is add a line to your own README or install docs pointing at it.
The pitch to make there is the same differentiator: this isn't a random
third-party mirror, it's **signed, test-gated, and audit-trailed** —

- **Signed** — GPG-signed apt indexes, verified by `apt` itself via
  `signed-by=`, not just a downloaded script you have to trust blind.
- **Test-gated** — lintian plus a container smoke test verifies every build
  before it ships, so a broken package never reaches `apt install`.
- **Audit-trailed** — every build is a public CI run against a pinned,
  checksum-verified upstream release, reviewed as a draft before publish. A
  user (or their security team) can trace exactly what they're running back
  to your release.

That's a materially stronger story than the `curl | sh` snippet most projects
default to, and it costs you one paragraph. Suggested copy for a "Debian /
Ubuntu" section in your install docs:

```markdown
### Debian & Ubuntu (unofficial, via latest-debs)

Signed, test-gated .deb packages, rebuilt automatically on every release:

    sudo install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://raw.githubusercontent.com/latest-debs/apt-repo/main/latest-debs.asc \
      | sudo gpg --dearmor --yes -o /etc/apt/keyrings/latest-debs.gpg
    echo "deb [signed-by=/etc/apt/keyrings/latest-debs.gpg] https://latest-debs.ranjithraj.workers.dev/ $(lsb_release -sc) main" \
      | sudo tee /etc/apt/sources.list.d/latest-debs.list
    sudo apt update
    sudo apt install yourtool

See https://github.com/latest-debs/yourtool-debian for details, or
https://latest-debs.github.io for how the packaging pipeline works.
```

Swap `yourtool` for your package name, and drop the extrepo lines in favor of
the manual `sources.list.d` snippet from [README.md](README.md#install) if
you'd rather not depend on `extrepo`. If you later ship your own official apt
repo, see [above](#were-complementary-to-upstream-not-competing-with-it) —
we'll update or remove the link, no questions asked.

## Get started

Open a [package request](https://github.com/latest-debs/apt-repo/issues/new?template=package-request.yml)
— tool name, upstream URL, and license is all we need. Valid requests are
validated, vetted, and scaffolded automatically.

See [README.md](README.md) for the full channel, the supply-chain & provenance
details, and the support expectations.
