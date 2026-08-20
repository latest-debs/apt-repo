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
 */

const POOL_PATH = /^\/pool\/([^/]+)\/([^/]+)\/([^/]+)$/;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    const poolMatch = url.pathname.match(POOL_PATH);
    if (poolMatch) {
      return handlePool(poolMatch, env, ctx);
    }

    return proxyToOrigin(request, url, env);
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

async function proxyToOrigin(request, url, env) {
  const originUrl = new URL(
    url.pathname.replace(/^\//, "") + url.search,
    env.ORIGIN_BASE,
  );

  const originResp = await fetch(originUrl.toString(), {
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
