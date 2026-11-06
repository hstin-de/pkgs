import { describe, expect, test } from "bun:test";
import { arch } from "./arch.js";

const files = {
  x86_64: { "otterlink_0.8.0_linux_amd64.pkg.tar.zst": "otterlink/v0.8.0", "otterlink_0.8.0_linux_amd64.pkg.tar.zst.sig": "otterlink/v0.8.0" },
  aarch64: {},
};
const env = {
  ASSETS: {
    fetch: async (r) => {
      const url = new URL(r.url ?? r);
      if (url.pathname === "/arch/files.json") return Response.json(files);
      return new Response(`static ${url.pathname}`);
    },
  },
  DL: {
    head: async () => null,
    get: async (key) =>
      key === "otterlink/v0.8.0/otterlink_0.8.0_linux_amd64.pkg.tar.zst"
        ? { size: 3, httpEtag: '"e"', range: { offset: 0, length: 3 }, body: "pkg" }
        : null,
  },
};
const get = (path) => arch(new Request(`https://pkgs.test/arch/${path}`), env, path.split("/"));

describe("arch", () => {
  test("a package from R2", async () => {
    const r = await get("x86_64/otterlink_0.8.0_linux_amd64.pkg.tar.zst");
    expect(r.status).toBe(200);
    expect(await r.text()).toBe("pkg");
    expect(r.headers.get("content-type")).toBe("application/octet-stream");
  });
  test("the database and hstin-repo are static", async () => {
    expect(await (await get("x86_64/hstin.db")).text()).toBe("static /arch/x86_64/hstin.db");
    expect(await (await get("x86_64/hstin-repo-1.0.0-1-any.pkg.tar.zst")).text()).toBe("static /arch/x86_64/hstin-repo-1.0.0-1-any.pkg.tar.zst");
  });
  test("a package of another architecture is not found in R2", async () => {
    expect(await (await get("aarch64/otterlink_0.8.0_linux_amd64.pkg.tar.zst")).text()).toStartWith("static");
  });
  test("no lookups outside the map", async () => {
    expect(await (await get("x86_64/constructor.pkg.tar.zst")).text()).toStartWith("static");
    expect(await (await get("x86_64/..pkg.tar.zst")).text()).toStartWith("static");
  });
});
