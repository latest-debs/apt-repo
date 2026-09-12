/**
 * apt-repo redirector.
 *
 * Serves the latest-debs apt repository at one origin without hosting any
 * package bytes itself:
 *
 *  - /pool/<suite>/<pkg>/<filename>  -> 302 to that tool's own GitHub
 *    Release asset (latest-debs/<pkg>-debian), via the pkg -> {repo, tag}
 *    map that build-repo.sh emits to dists/pkg-repo-map.json.
 *  - everything else (/dists/*, /, the signing key, licenses.json, ...)
 *    -> transparently proxied from ORIGIN_BASE (the apt-repo GitHub Pages
 *    site), which stays index-only and KB-scale.
 *
 * apt's Filename field is always resolved relative to the repo's base URI
 * (verified: it does not follow absolute URLs there - see
 * PLATFORM-EVALUATION.md, "Decision", step 4), so dists/ and pool/ must
 * share one origin. This Worker *is* that shared origin.
 *
 * Every request is also counted into Workers Analytics Engine (the AE
 * binding) by suite, architecture, and package - the only place in the
 * stack that sees real apt clients. See README.md, "Usage analytics".
 */

const POOL_PATH = /^\/pool\/([^/]+)\/([^/]+)\/([^/]+)$/;
const DISTS_PATH = /^\/dists\/([^/]+)\//;
const BINARY_ARCH = /\/binary-([^/]+)\//;
const DEB_ARCH = /_([a-z0-9]+)\.deb$/;
const SOURCE_EXT = /\.(dsc|tar\.[gx]z)$/;

export default {
  async scheduled(event, env, ctx) {
    ctx.waitUntil(runWatchdog(env));
  },

  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // apt clients - and extrepo's own tools/validate-repo - build URLs by
    // joining the base URI, which ends in "/", with "/dists/...", so
    // "//dists/..." arrives routinely. It must be collapsed before routing:
    // proxyToOrigin resolves the path against ORIGIN_BASE, and any path
    // still carrying a leading slash resolves as absolute, silently
    // dropping the base's "/apt-repo/" prefix and 404ing on GitHub Pages.
    // The old Pages origin normalised this server-side; we have to do it
    // ourselves.
    const pathname = normalizePath(url.pathname);
    const poolMatch = pathname.match(POOL_PATH);

    const response = poolMatch
      ? await handlePool(poolMatch, env, ctx)
      : await proxyToOrigin(request, pathname, url.search, env);

    // waitUntil, not await: never make a package download wait on a metric.
    ctx.waitUntil(recordHit(request, pathname, env, poolMatch, response.status));

    return response;
  },
};

async function handlePool([, , pkg, filename], env, ctx) {
  let map;
  try {
    map = await getPkgRepoMap(env, ctx);
  } catch (err) {
    return new Response(`manifest fetch failed: ${err.message}\n`, {
      status: 502,
    });
  }

  const entry = map[pkg];
  if (!entry) {
    return new Response(
      `unknown package "${pkg}" - not present in pkg-repo-map.json\n`,
      { status: 404 },
    );
  }

  const target =
    `https://github.com/${entry.repo}/releases/download/` +
    `${encodeURIComponent(entry.tag)}/${filename}`;

  // 302, not 301: tags get superseded on every release, so this mapping is
  // expected to change over the package's lifetime.
  return Response.redirect(target, 302);
}

async function getPkgRepoMap(env, ctx) {
  const cache = caches.default;
  const cacheKey = new Request(env.MANIFEST_URL);

  let resp = await cache.match(cacheKey);
  if (!resp) {
    resp = await fetch(env.MANIFEST_URL, {
      cf: { cacheTtl: 60, cacheEverything: true },
    });
    if (resp.ok) {
      ctx.waitUntil(cache.put(cacheKey, resp.clone()));
    }
  }

  if (!resp.ok) {
    throw new Error(`GET ${env.MANIFEST_URL} -> ${resp.status}`);
  }
  return resp.json();
}

/**
 * Collapse repeated slashes. Exported for tests.
 *
 * apt and extrepo's tools/validate-repo both join a base URI ending in "/"
 * with "/dists/...", so "//dists/..." is a normal request, not a malformed
 * one.
 */
export function normalizePath(pathname) {
  return pathname.replace(/\/{2,}/g, "/");
}

/**
 * Resolve a request path against ORIGIN_BASE. Exported for tests.
 *
 * The join must stay *relative* so it lands under the base's own
 * "/apt-repo/" path - any leading slash left on the path makes `new URL`
 * treat it as absolute and drop that prefix, which is exactly how
 * "//dists/..." used to 404.
 */
export function originUrlFor(pathname, search, base) {
  return new URL(normalizePath(pathname).replace(/^\//, "") + search, base)
    .toString();
}

async function proxyToOrigin(request, pathname, search, env) {
  const originUrl = originUrlFor(pathname, search, env.ORIGIN_BASE);

  const originResp = await fetch(originUrl, {
    method: request.method,
    cf: { cacheTtl: 300, cacheEverything: true },
  });

  // Strip hop-by-hop / origin-identifying headers rather than passing the
  // GitHub Pages response through verbatim.
  const headers = new Headers(originResp.headers);
  headers.delete("set-cookie");

  return new Response(originResp.body, {
    status: originResp.status,
    statusText: originResp.statusText,
    headers,
  });
}

/* -------------------------------------------------------------------
 * Usage analytics
 *
 * MARKET-ANALYSIS.md's open problem: 51,760 release-asset downloads that
 * cannot be told apart from crawlers, and no way to prove which suite or
 * architecture is actually being pulled. GitHub's asset counter only sees
 * the 302 target, with no suite/arch context; this Worker sees the real
 * apt request, so it is the only place that breakdown exists.
 * ------------------------------------------------------------------- */

/** Derive {kind, suite, arch, pkg} from a request path. Exported for tests. */
export function classify(pathname, poolMatch) {
  if (poolMatch) {
    const [, suite, pkg, filename] = poolMatch;
    return { kind: "pool", suite, arch: archFromFilename(filename), pkg };
  }

  const dists = pathname.match(DISTS_PATH);
  if (dists) {
    const arch = pathname.match(BINARY_ARCH);
    // binary-<arch>/Packages is the per-arch index; /dists/<suite>/Release
    // and InRelease are suite-wide and carry no architecture.
    return {
      kind: "index",
      suite: dists[1],
      arch: arch ? arch[1] : "-",
      pkg: "-",
    };
  }

  return { kind: "other", suite: "-", arch: "-", pkg: "-" };
}

/** Architecture from a pool filename, per build-repo.sh's naming scheme. */
export function archFromFilename(filename) {
  const deb = filename.match(DEB_ARCH);
  if (deb) return deb[1];
  // .dsc / .debian.tar.xz / .orig.tar.gz - one source package per suite,
  // with no architecture of its own.
  if (SOURCE_EXT.test(filename)) return "source";
  return "-";
}

/**
 * A daily-rotating, salted digest of IP + User-Agent.
 *
 * Enough to count distinct clients within a day; deliberately useless as a
 * durable identifier, since the salt changes at UTC midnight. CLIENT_SALT
 * is a Worker secret - WITHOUT it the digest is only date-salted, and the
 * whole IPv4 space is cheap to brute-force against a known hash, so treat
 * the field as unsafe until that secret is set (see README.md).
 */
export async function clientDigest(request, env) {
  // Fail closed. With no secret the only salt is the date, and the whole
  // IPv4 space is cheap to brute-force against a known digest - so record
  // nothing rather than a weak hash of a visitor's address. The suite,
  // arch and package breakdown still works without this field, and that is
  // the number positioning actually turns on.
  if (!env.CLIENT_SALT) return "-";

  const ip = request.headers.get("cf-connecting-ip") ?? "";
  const ua = request.headers.get("user-agent") ?? "";
  const day = new Date().toISOString().slice(0, 10);

  const bytes = new TextEncoder().encode(
    `${day} ${env.CLIENT_SALT} ${ip} ${ua}`,
  );
  const digest = await crypto.subtle.digest("SHA-256", bytes);

  return [...new Uint8Array(digest).slice(0, 8)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function recordHit(request, pathname, env, poolMatch, status) {
  // Unbound in `wrangler dev` and `--dry-run`; absence must not throw.
  if (!env.AE) return;

  try {
    const { kind, suite, arch, pkg } = classify(pathname, poolMatch);

    env.AE.writeDataPoint({
      blobs: [
        kind,
        suite,
        arch,
        pkg,
        request.cf?.country ?? "-",
        await clientDigest(request, env),
      ],
      // doubles[0] is a constant 1 so SUM(_sample_interval * double1) reads
      // as a hit count once Analytics Engine starts sampling.
      doubles: [1, status],
      // Sampling key: keeps each suite's series intact under sampling
      // rather than letting a busy suite crowd out a quiet one.
      indexes: [suite],
    });
  } catch {
    // Instrumentation must never break package serving.
  }
}

/* -------------------------------------------------------------------
 * External liveness watchdog
 *
 * Everything else that watches this project runs inside the same GitHub
 * org as the thing it watches: rebuild.yml, staleness.yml and
 * report-workflow-failure.sh all go dark together. A green pipeline is
 * also not the same claim as a healthy archive - build-repo.sh can publish
 * a suite whose Filename: fields 302 to assets upstream has since deleted,
 * and every `apt install` fails while `apt update` and CI stay green.
 *
 * This runs on Cloudflare's cron, on a different account, on a different
 * platform, and checks the published archive the way apt does:
 *
 *   1. the origin's signed Release exists and was stamped recently,
 *   2. this Worker still serves it end to end - via "//dists/...", the
 *      double-slash form apt and extrepo actually send, which 404'd in
 *      production once already,
 *   3. the first Filename: in the index really is downloadable: our 302
 *      resolves, and the GitHub asset behind it still exists.
 *
 * A failure opens (and a recovery closes) one `origin-unhealthy` tracking
 * issue. That label is deliberately NOT `pipeline-failure`: that issue is
 * shared by the two in-org workflows and its all-clear is computed from
 * their run status, which says nothing about whether the archive serves.
 * ------------------------------------------------------------------- */

const WATCHDOG_SUITE = "trixie";
const WATCHDOG_ARCH = "amd64";
const WATCHDOG_STALE_HOURS = 48;
const WATCHDOG_LABEL = "origin-unhealthy";
const WATCHDOG_TITLE = "External watchdog: the published apt origin is unhealthy";

/**
 * Run the three checks. Returns a list of human-readable failures - empty
 * means healthy. Exported, with `fetchImpl` injectable, for tests.
 */
export async function checkOrigin(env, fetchImpl = fetch) {
  const failures = [];
  const suite = env.WATCHDOG_SUITE || WATCHDOG_SUITE;
  const staleHours = Number(env.WATCHDOG_STALE_HOURS || WATCHDOG_STALE_HOURS);
  const publicBase = (env.PUBLIC_BASE || "").replace(/\/$/, "");
  const releasePath = `dists/${suite}/Release`;

  // 1. The origin's Release, and how old the archive says it is.
  let release = null;
  try {
    const resp = await fetchImpl(new URL(releasePath, env.ORIGIN_BASE).toString());
    if (!resp.ok) {
      failures.push(`origin ${releasePath} -> HTTP ${resp.status}`);
    } else {
      release = await resp.text();
      const stamped = release.match(/^Date:\s*(.+)$/m);
      const at = stamped ? Date.parse(stamped[1]) : NaN;
      if (Number.isNaN(at)) {
        failures.push(`origin ${releasePath} has no parsable Date: field`);
      } else {
        const ageHours = (Date.now() - at) / 3600000;
        if (ageHours > staleHours) {
          failures.push(
            `origin ${releasePath} was stamped ${Math.round(ageHours)}h ago ` +
              `(window ${staleHours}h) - the rebuild has stopped publishing`,
          );
        }
      }
    }
  } catch (err) {
    failures.push(`origin ${releasePath} threw: ${err.message}`);
  }

  if (!publicBase) return failures;

  // 2. This Worker, end to end, in the double-slash form apt sends.
  try {
    const resp = await fetchImpl(`${publicBase}//${releasePath}`);
    if (!resp.ok) failures.push(`worker //${releasePath} -> HTTP ${resp.status}`);
  } catch (err) {
    failures.push(`worker //${releasePath} threw: ${err.message}`);
  }

  // 3. The index's own first Filename:, fetched the way apt would.
  try {
    const arch = env.WATCHDOG_ARCH || WATCHDOG_ARCH;
    const idxPath = `dists/${suite}/main/binary-${arch}/Packages`;
    const idx = await fetchImpl(new URL(idxPath, env.ORIGIN_BASE).toString());
    if (!idx.ok) {
      failures.push(`origin ${idxPath} -> HTTP ${idx.status}`);
    } else {
      const named = (await idx.text()).match(/^Filename:\s*(.+)$/m);
      if (!named) {
        failures.push(`origin ${idxPath} lists no Filename: - the suite is empty`);
      } else {
        const filename = named[1].trim();
        const hop = await fetchImpl(`${publicBase}/${filename}`, { redirect: "manual" });
        const target = hop.headers.get("location");
        if (hop.status !== 302 || !target) {
          failures.push(`worker /${filename} -> HTTP ${hop.status}, expected a 302`);
        } else {
          // The 302 resolving is only half the promise: apt install fails
          // just as hard when the release asset behind it is gone.
          const asset = await fetchImpl(target, { method: "HEAD" });
          if (!asset.ok) {
            failures.push(`/${filename} 302s to ${target} -> HTTP ${asset.status}`);
          }
        }
      }
    }
  } catch (err) {
    failures.push(`pool check threw: ${err.message}`);
  }

  return failures;
}

async function runWatchdog(env) {
  const failures = await checkOrigin(env);

  // Fail soft, and loudly in the log: an unset token must never turn a
  // real outage into a thrown scheduled event that reports nothing.
  if (!env.ALERT_TOKEN) {
    console.log(
      failures.length
        ? `watchdog: UNHEALTHY, no ALERT_TOKEN to report with: ${failures.join("; ")}`
        : "watchdog: healthy",
    );
    return;
  }

  const repo = env.ALERT_REPO || "latest-debs/apt-repo";
  const gh = (path, init) =>
    fetch(`https://api.github.com/repos/${repo}${path}`, {
      ...init,
      headers: {
        authorization: `Bearer ${env.ALERT_TOKEN}`,
        accept: "application/vnd.github+json",
        "user-agent": "latest-debs-external-watchdog",
        ...(init?.body ? { "content-type": "application/json" } : {}),
      },
    });

  const open = await gh(`/issues?state=open&labels=${WATCHDOG_LABEL}`)
    .then((r) => (r.ok ? r.json() : []))
    .catch(() => []);
  const existing = open.find((i) => !i.pull_request);

  if (failures.length === 0) {
    if (existing) {
      await gh(`/issues/${existing.number}/comments`, {
        method: "POST",
        body: JSON.stringify({ body: "External watchdog: the origin is serving again." }),
      });
      await gh(`/issues/${existing.number}`, {
        method: "PATCH",
        body: JSON.stringify({ state: "closed" }),
      });
    }
    console.log("watchdog: healthy");
    return;
  }

  const body =
    `The external liveness check (Cloudflare cron, outside this org) failed at ` +
    `${new Date().toISOString()}:\n\n` +
    failures.map((f) => `- ${f}`).join("\n") +
    `\n\nThis watches the published archive, not the pipeline - CI can be ` +
    `green while this is red. Source: \`redirector/src/worker.js\`, ` +
    `\`checkOrigin()\`.\n`;

  if (existing) {
    await gh(`/issues/${existing.number}/comments`, {
      method: "POST",
      body: JSON.stringify({ body }),
    });
  } else {
    // 422 = the label already exists, which is the normal case.
    await gh("/labels", {
      method: "POST",
      body: JSON.stringify({
        name: WATCHDOG_LABEL,
        color: "d93f0b",
        description: "The published apt origin failed an external liveness check",
      }),
    }).catch(() => {});
    await gh("/issues", {
      method: "POST",
      body: JSON.stringify({
        title: WATCHDOG_TITLE,
        labels: [WATCHDOG_LABEL],
        body,
      }),
    });
  }
  console.log(`watchdog: UNHEALTHY - ${failures.join("; ")}`);
}
