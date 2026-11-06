import { describe, expect, test } from "bun:test";
import { serve } from "./dl.js";

// A bucket like R2's binding for one object, with ranges and conditions.
function bucket(objects) {
  const meta = (key, data) => ({
    key,
    size: data.length,
    httpEtag: `"${key.length}"`,
    writeHttpMetadata: (h) => h.set("content-type", "application/octet-stream"),
  });
  return {
    async head(key) {
      return key in objects ? meta(key, objects[key]) : null;
    },
    async get(key, opts) {
      if (!(key in objects)) return null;
      const data = objects[key];
      const m = meta(key, data);
      const inm = opts?.onlyIf?.get?.("if-none-match");
      if (inm && inm === m.httpEtag) return m; // no body: precondition failed
      const range = opts?.range?.get?.("range");
      if (range) {
        const [, a, b] = /^bytes=(\d*)-(\d*)$/.exec(range);
        if (a === "") {
          const suffix = Number(b);
          return { ...m, range: { suffix }, body: data.slice(data.length - suffix) };
        }
        const offset = Number(a);
        const length = b === "" ? data.length - offset : Number(b) - offset + 1;
        return { ...m, range: { offset, length }, body: data.slice(offset, offset + length) };
      }
      return { ...m, range: { offset: 0, length: data.length }, body: data };
    },
  };
}

const b = bucket({ "otterlink/v0.8.0/otterlink_0.8.0_linux_amd64.deb": "0123456789" });
const req = (method = "GET", headers = {}) => new Request("https://pkgs.test/x", { method, headers });
const path = ["otterlink", "v0.8.0", "otterlink_0.8.0_linux_amd64.deb"];

describe("serve", () => {
  test("a file", async () => {
    const r = await serve(req(), b, path);
    expect(r.status).toBe(200);
    expect(await r.text()).toBe("0123456789");
    expect(r.headers.get("content-length")).toBe("10");
    expect(r.headers.get("cache-control")).toContain("immutable");
  });
  test("HEAD", async () => {
    const r = await serve(req("HEAD"), b, path);
    expect(r.status).toBe(200);
    expect(r.headers.get("content-length")).toBe("10");
  });
  test("a range", async () => {
    const r = await serve(req("GET", { range: "bytes=2-4" }), b, path);
    expect(r.status).toBe(206);
    expect(r.headers.get("content-range")).toBe("bytes 2-4/10");
    expect(await r.text()).toBe("234");
  });
  test("a suffix range", async () => {
    const r = await serve(req("GET", { range: "bytes=-3" }), b, path);
    expect(r.headers.get("content-range")).toBe("bytes 7-9/10");
  });
  test("not modified", async () => {
    const etag = (await serve(req(), b, path)).headers.get("etag");
    const r = await serve(req("GET", { "if-none-match": etag }), b, path);
    expect(r.status).toBe(304);
  });
  test("missing and malformed paths", async () => {
    for (const p of [
      ["otterlink", "v0.8.0", "missing.deb"],
      ["otterlink", "v0.8.0"],
      ["otterlink", "..", "x"],
      ["otterlink", "v0.8.0", ".hidden"],
      ["a", "b", "c", "d"],
      "otterlink/v0.8.0/a%2Fb",
      undefined,
    ]) {
      expect((await serve(req(), b, p)).status).toBe(404);
    }
  });
  test("only GET and HEAD", async () => {
    expect((await serve(req("PUT"), b, path)).status).toBe(405);
  });
  test("served as a download, never as a page", async () => {
    const r = await serve(req(), b, path);
    expect(r.headers.get("content-type")).toBe("application/octet-stream");
    expect(r.headers.get("content-disposition")).toContain("attachment");
    expect(r.headers.get("x-content-type-options")).toBe("nosniff");
    expect(r.headers.get("content-security-policy")).toContain("sandbox");
  });
  test("a failed precondition is not cached", async () => {
    const strict = { ...b, get: async (key, opts) => ({ ...(await b.head(key)) }) };
    const r = await serve(req("GET", { "if-match": '"x"' }), strict, path);
    expect(r.status).toBe(412);
    expect(r.headers.get("cache-control")).toBe("no-store");
  });
  test("a range R2 rejects", async () => {
    const broken = { ...b, get: async () => { throw new Error("InvalidRange"); } };
    expect((await serve(req("GET", { range: "bytes=99-" }), broken, path)).status).toBe(416);
  });
  test("HEAD not modified", async () => {
    const etag = (await serve(req("HEAD"), b, path)).headers.get("etag");
    expect((await serve(req("HEAD", { "if-none-match": etag }), b, path)).status).toBe(304);
  });
  test("a string path", async () => {
    expect((await serve(req(), b, path.join("/"))).status).toBe(200);
  });
});
