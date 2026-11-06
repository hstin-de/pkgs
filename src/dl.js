// Serves the release files from the R2 bucket (binding DL) under three
// prefixes of pkgs.hstin.de: /apt/pool/, /rpm/pool/ (the repositories'
// package paths) and /dl/ (download pages, update clients). The bucket
// stays private; keys are <project>/<tag>/<file>.

const segment = /^[A-Za-z0-9][A-Za-z0-9._+-]*$/;

// Release files are never shown as pages of pkgs.hstin.de, whatever they
// are: text as text, everything else as a download, nothing runs.
function security(headers, name) {
  const text = name === "SHA256SUMS" || name.endsWith(".txt");
  headers.set("content-type", text ? "text/plain; charset=utf-8" : "application/octet-stream");
  if (!text) headers.set("content-disposition", `attachment; filename="${name}"`);
  headers.set("x-content-type-options", "nosniff");
  headers.set("content-security-policy", "sandbox; default-src 'none'");
}

/**
 * @param {Request} request
 * @param {R2Bucket} bucket
 * @param {string[] | string | undefined} parts the path below the prefix
 */
export async function serve(request, bucket, parts) {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("method not allowed\n", { status: 405, headers: { allow: "GET, HEAD" } });
  }
  const path = Array.isArray(parts) ? parts : String(parts ?? "").split("/");
  if (path.length !== 3 || !path.every((s) => segment.test(s) && !s.includes(".."))) {
    return new Response("not found\n", { status: 404 });
  }
  const key = path.join("/");
  let obj;
  try {
    obj =
      request.method === "HEAD"
        ? await bucket.head(key)
        : await bucket.get(key, { onlyIf: request.headers, range: request.headers });
  } catch {
    // R2 rejects ranges it cannot satisfy.
    return request.headers.has("range")
      ? new Response("range not satisfiable\n", { status: 416 })
      : new Response("error\n", { status: 500 });
  }
  if (obj === null) {
    return new Response("not found\n", { status: 404 });
  }
  const headers = new Headers();
  security(headers, path[2]);
  headers.set("etag", obj.httpEtag);
  headers.set("accept-ranges", "bytes");
  // A release's files never change.
  headers.set("cache-control", "public, max-age=31536000, immutable");
  if (request.method === "HEAD") {
    if (request.headers.get("if-none-match") === obj.httpEtag) {
      return new Response(null, { status: 304, headers });
    }
    headers.set("content-length", String(obj.size));
    return new Response(null, { headers });
  }
  if (!("body" in obj) || obj.body === undefined) {
    // A precondition failed.
    const conditional = request.headers.has("if-none-match") || request.headers.has("if-modified-since");
    if (!conditional) headers.set("cache-control", "no-store");
    return new Response(null, { status: conditional ? 304 : 412, headers });
  }
  const r = obj.range;
  if (r && request.headers.has("range")) {
    let start, length;
    if ("suffix" in r) {
      length = Math.min(r.suffix, obj.size);
      start = obj.size - length;
    } else {
      start = r.offset ?? 0;
      length = r.length ?? obj.size - start;
    }
    headers.set("content-range", `bytes ${start}-${start + length - 1}/${obj.size}`);
    headers.set("content-length", String(length));
    return new Response(obj.body, { status: 206, headers });
  }
  headers.set("content-length", String(obj.size));
  return new Response(obj.body, { headers });
}
