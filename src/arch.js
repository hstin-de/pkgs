// Serves the pacman repositories under /arch/<arch>/ of pkgs.hstin.de: the
// databases and hstin-repo are static files of the site; the projects'
// packages and their signatures come from the R2 bucket, where files.json
// (written by scripts/build.sh) says which release holds each.
import { serve } from "./dl.js";

const arches = new Set(["x86_64", "aarch64"]);
const pkg = /^[A-Za-z0-9][A-Za-z0-9._+-]*\.pkg\.tar\.zst(\.sig)?$/;

/**
 * @param {Request} request
 * @param {{ASSETS: Fetcher, DL: R2Bucket}} env
 * @param {string[] | string | undefined} parts the path below /arch/
 */
export async function arch(request, env, parts) {
  const path = Array.isArray(parts) ? parts : String(parts ?? "").split("/");
  if (path.length === 2 && arches.has(path[0]) && pkg.test(path[1]) && !path[1].includes("..")) {
    const res = await env.ASSETS.fetch(new URL("/arch/files.json", request.url));
    const files = res.ok ? await res.json() : {};
    const at = Object.hasOwn(files[path[0]] ?? {}, path[1]) ? files[path[0]][path[1]] : undefined;
    if (typeof at === "string" && at.split("/").length === 2) {
      return serve(request, env.DL, [...at.split("/"), path[1]]);
    }
  }
  return env.ASSETS.fetch(request);
}
