// Cloudflare Pages Function — GET /api/release
// Proxies the latest GitHub release for the public repo (no token needed
// for public repos; keeps the landing page free of API keys).

const REPO = "rkobroo/screenmirror";

export async function onRequestGet() {
  try {
    const res = await fetch(
      `https://api.github.com/repos/${REPO}/releases/latest`,
      {
        headers: {
          Accept: "application/vnd.github+json",
          "User-Agent": "MirrorLink-website"
        },
        cf: { cacheTtl: 300, cacheEverything: true }
      }
    );

    if (!res.ok) {
      return json({ error: `github:${res.status}` }, 502);
    }

    const data = await res.json();

    const assets = (data.assets || []).map((a) => ({
      name: a.name,
      url: a.browser_download_url,
      size: a.size
    }));

    return json({
      tag_name: data.tag_name,
      name: data.name,
      html_url: data.html_url,
      published_at: data.published_at,
      body: data.body || "",
      android: assets.find((a) => /\.apk$/i.test(a.name)) || null,
      windows: assets.find((a) => /\.exe$/i.test(a.name)) || null
    });
  } catch (err) {
    return json({ error: "unreachable" }, 502);
  }
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "public, max-age=300"
    }
  });
}
