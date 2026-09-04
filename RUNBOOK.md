# Key custody & succession runbook

The dependencies that **cannot be recreated from this repo** if their holder
is unavailable. Everything else about this pipeline is public and
reproducible; these are not, which is the only reason this file exists.

Scoped deliberately: `ORG_ADMIN_TOKEN` and `TRIGGER_TOKEN` are *not* covered
here because they're re-issuable from scratch by any org owner in minutes —
see the README's [package-request setup](README.md#maintainers-automating-a-package-request)
and `scripts/set-trigger-secret.sh`'s usage header. Never escrow those; issue
fresh ones.

**Closed:** GitHub org bus-factor — the org has held **two owners since
2026-09-04**. An org owner has admin on every repo, so either maintainer can
administer, release, rotate secrets, and recover the org alone.

## 1. Cloudflare Worker — the origin (top risk)

`redirector/` deploys the Worker that apt clients actually talk to. It lives
on a **personal Cloudflare account** at `latest-debs.ranjithraj.workers.dev`,
on the free `*.workers.dev` tier (see `PLATFORM-EVALUATION.md`).

That hostname is the `URIs:` in `extrepo/latest-debs.yaml`, contributed
upstream to [extrepo-data](https://salsa.debian.org/extrepo-team/extrepo-data).
**Users who ran `extrepo enable latest-debs` cannot be re-pointed by any
change made in this repo** — moving hosts needs an upstream MR plus a
`sources.list` edit by every manual-install user. Losing the account is a
total outage with a slow, externally-gated recovery.

Fixes, cheapest first:

1. **Add the other maintainer as a Cloudflare account owner** (Manage Account
   → Members). Free, one minute, removes the single-account dependency.
2. **Attach a real domain** and redirect the `workers.dev` URL to it. A
   domain transfers between maintainers; a personal `workers.dev` subdomain
   never can. This is the only permanent fix.

The Worker code is not at risk — anyone with an account can redeploy it with
`npx wrangler deploy` from `redirector/`. The *hostname* is the asset.

## 2. GPG signing key

Used by `scripts/sign-repo.sh` in the `Sign repository` step of
`rebuild.yml`, on every rebuild — so the private key sits in Actions secrets
(`APT_SIGNING_KEY`, `APT_SIGNING_KEY_PASS`), not only offline.

**Actions secrets are write-only.** They can be replaced but never read back,
by owners or anyone else. A second org owner therefore does *not* give you a
recoverable copy of this key. **Back it up out-of-band or it dies with its
laptop:**

```sh
gpg --export-secret-keys --armor <KEYID> > latest-debs-signing-key.asc
# store the passphrase separately; keep a copy with the other maintainer
```

**Rotation is externally gated.** The public half is published in three
places that must change together — `latest-debs.asc`/`latest-debs.gpg`, the
`gpg-key:` block in `extrepo/latest-debs.yaml`, and the copy in upstream
extrepo-data. That last one needs an MR and lands on Debian's schedule, so:
sign one rebuild with both keys during the overlap, update the Actions
secrets, commit the new public key, open the extrepo-data MR, and **only
retire the old key once it merges**. Users pinned to the old key fail
`apt update` until they re-import.

If the key is lost with no backup there is no recovery, only replacement —
and every existing user hits `NO_PUBKEY` until they re-import. Announce that
loudly; a silent signing-key change is indistinguishable from an attack.

**Rehearse before you need it:** sign a local `build-repo.sh` output with a
throwaway key and confirm `apt` accepts it with only that key trusted. Never
rehearsed as of 2026-09-04.

## Succession

Transfer, in order — each is useless without the ones above it:

1. **Cloudflare account access** (or a domain that can be re-pointed)
2. **GitHub org ownership** — already held by two maintainers ✅
3. **Signing key + passphrase** — must be handed over deliberately; it cannot
   be extracted from Actions

Tokens are re-issued, never escrowed. Day-to-day duties that come with it:
publish draft releases (`scripts/promote-drafts.sh`), work the
`stale-package` and `pipeline-failure` tracking issues, and review parity
candidates on the [status dashboard](https://latest-debs.github.io/status.html).
