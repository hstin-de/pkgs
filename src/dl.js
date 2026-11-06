// Serves the release files from the R2 bucket (binding DL) under three
// prefixes of pkgs.hstin.de: /apt/pool/, /rpm/pool/ (the repositories'
// package paths) and /dl/ (download pages, update clients). The bucket
// stays private; keys are <project>/<tag>/<file>.

const segment = /^[A-Za-z0-9][A-Za-z0-9._+-]*$/;

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
  const obj =
    request.method === "HEAD"
      ? await bucket.head(key)
      : await bucket.get(key, { onlyIf: request.headers, range: request.headers });
  if (obj === null) {
    return new Response("not found\n", { status: 404 });
  }
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("etag", obj.httpEtag);
  headers.set("accept-ranges", "bytes");
  // A release's files never change.
  headers.set("cache-control", "public, max-age=31536000, immutable");
  if (request.method === "HEAD") {
    headers.set("content-length", String(obj.size));
    return new Response(null, { headers });
  }
  if (!("body" in obj) || obj.body === undefined) {
    // A precondition failed.
    const conditional = request.headers.has("if-none-match") || request.headers.has("if-modified-since");
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
