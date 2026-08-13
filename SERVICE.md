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

- **All four Debian suites** — Bookworm (12), Trixie (13), Forky
  (14/testing), Sid (unstable).
- **Every architecture you actually publish a Linux binary for** — amd64,
  arm64, armhf, i386, ppc64el, riscv64, s390x, and we verify exactly which
  ones your release covers at vet time rather than assuming "all".
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
- **Human gate where it matters** — builds land as drafts that a maintainer
  reviews; nothing is auto-published past review.

### Near-instant updates

Publishing a release triggers an immediate apt-repo rebuild via webhook, with
a scheduled fallback — so users see new versions in minutes, not at the next
Debian release.

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

For projects that publish a Linux binary (`.tar.gz`, `.tgz`, or `.zip`) on
GitHub:

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

## Get started

Open a [package request](https://github.com/latest-debs/apt-repo/issues/new?template=package-request.yml)
— tool name, upstream URL, and license is all we need. Valid requests are
validated, vetted, and scaffolded automatically.

See [README.md](README.md) for the full channel, the supply-chain & provenance
details, and the support expectations.
