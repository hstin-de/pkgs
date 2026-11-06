// Package e2e checks pkgs.hstin.de end to end: test releases of two projects
// on a fake GitHub API go through scripts/sync.sh (digests, package names, rpm
// signing) into a local store, the site is built (scripts/build.sh) and served
// by `wrangler pages dev` with its functions and the store as the R2 bucket,
// and hstin-repo, the install script, apt, dnf and pacman install from it in
// Debian, Fedora and Arch containers.
//
//	go test -count=1 -v ./e2e/
package e2e

import (
	"bytes"
	"crypto/sha1" //nolint:gosec // git's object ids
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"
)

const toolsImage = "hstin-pkgs-tools"

// The tools image is the deploy's runner (ubuntu-24.04) with the same packages.
const toolsDockerfile = `FROM goreleaser/nfpm:latest AS nfpm
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends apt-utils createrepo-c rpm gnupg ca-certificates curl jq \
  pacman-package-manager makepkg libarchive-tools zstd && rm -rf /var/lib/apt/lists/*
COPY --from=nfpm /usr/bin/nfpm /usr/bin/nfpm
`

// wranglerImage runs wrangler, installed from package-lock.json.
const wranglerImage = "node:22"

const token = "test-token"

func repoRoot() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(file), "..")
}

func docker(t *testing.T, args ...string) string {
	t.Helper()
	out, err := exec.Command("docker", args...).CombinedOutput()
	if err != nil {
		t.Fatalf("docker %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return string(out)
}

// user runs containers that write into the test's directory as the test's
// user, so it can clean up.
func user() string { return fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid()) }

func freePort(t *testing.T) int {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func serve(t *testing.T, h http.Handler) string {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: h}
	go func() { _ = srv.Serve(l) }()
	t.Cleanup(func() { _ = srv.Close() })
	return "http://" + l.Addr().String()
}

func nfpmConfig(name, arch, v string) string {
	return "name: " + name + "\narch: " + arch + "\nplatform: linux\nversion: " + v + `
maintainer: test <test@example.com>
description: test package
license: Apache-2.0
contents:
  - src: /work/bin/pkg
    dst: /usr/bin/` + name + `
    file_info: {mode: 0755}
`
}

// A release on the fake GitHub.
type release struct {
	repo, tag  string
	packages   []string
	draft, pre bool
	badDigest  bool // one asset's recorded digest is wrong
	dir        string
}

// fakeGitHub serves the parts of the GitHub API sync.sh uses: releases,
// their assets (with digests) and the contents of the branch pkgs.
func fakeGitHub(t *testing.T, rels []*release, updates map[string]string) string {
	var base string
	mux := http.NewServeMux()
	auth := func(h http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("Authorization") != "Bearer "+token {
				http.Error(w, `{"message":"Bad credentials"}`, http.StatusUnauthorized)
				return
			}
			h(w, r)
		}
	}
	type asset struct {
		Name   string `json:"name"`
		URL    string `json:"url"`
		Digest string `json:"digest"`
	}
	type ghRelease struct {
		Tag        string  `json:"tag_name"`
		Draft      bool    `json:"draft"`
		Prerelease bool    `json:"prerelease"`
		Assets     []asset `json:"assets"`
	}
	view := func(rel *release) ghRelease {
		g := ghRelease{Tag: rel.tag, Draft: rel.draft, Prerelease: rel.pre}
		entries, _ := os.ReadDir(rel.dir)
		for i, e := range entries {
			b, _ := os.ReadFile(filepath.Join(rel.dir, e.Name()))
			sum := sha256.Sum256(b)
			if rel.badDigest && i == 0 {
				sum[0] ^= 1
			}
			g.Assets = append(g.Assets, asset{e.Name(), base + "/assets/" + rel.repo + "/" + rel.tag + "/" + e.Name(), "sha256:" + hex.EncodeToString(sum[:])})
		}
		return g
	}
	mux.HandleFunc("GET /repos/{owner}/{repo}/releases", auth(func(w http.ResponseWriter, r *http.Request) {
		list := []ghRelease{}
		for i := len(rels) - 1; i >= 0; i-- {
			if rels[i].repo == r.PathValue("owner")+"/"+r.PathValue("repo") {
				list = append(list, view(rels[i]))
			}
		}
		_ = json.NewEncoder(w).Encode(list)
	}))
	mux.HandleFunc("GET /repos/{owner}/{repo}/releases/tags/{tag}", auth(func(w http.ResponseWriter, r *http.Request) {
		for _, rel := range rels {
			if rel.repo == r.PathValue("owner")+"/"+r.PathValue("repo") && rel.tag == r.PathValue("tag") {
				_ = json.NewEncoder(w).Encode(view(rel))
				return
			}
		}
		http.NotFound(w, r)
	}))
	mux.HandleFunc("GET /assets/{owner}/{repo}/{tag}/{name}", auth(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Accept") != "application/octet-stream" {
			http.Error(w, "json", http.StatusNotAcceptable)
			return
		}
		for _, rel := range rels {
			if rel.repo == r.PathValue("owner")+"/"+r.PathValue("repo") && rel.tag == r.PathValue("tag") {
				http.ServeFile(w, r, filepath.Join(rel.dir, filepath.Base(r.PathValue("name"))))
				return
			}
		}
		http.NotFound(w, r)
	}))
	mux.HandleFunc("GET /repos/hstin-de/otterlink/contents/updates", auth(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("ref") != "pkgs" {
			http.NotFound(w, r)
			return
		}
		type entry struct {
			Name string `json:"name"`
			Type string `json:"type"`
			SHA  string `json:"sha"`
		}
		list := []entry{{"README.md", "file", blobSHA([]byte("readme"))}}
		for n, b := range updates {
			list = append(list, entry{n, "file", blobSHA([]byte(b))})
		}
		_ = json.NewEncoder(w).Encode(list)
	}))
	// Like GitHub: a file through the contents API comes back as UTF-8 with
	// invalid bytes replaced (raw and base64 alike), which breaks binary
	// signatures; the git blob API gives the exact bytes.
	mux.HandleFunc("GET /repos/hstin-de/otterlink/contents/updates/{name}", auth(func(w http.ResponseWriter, r *http.Request) {
		b, ok := updates[r.PathValue("name")]
		if !ok || r.URL.Query().Get("ref") != "pkgs" {
			http.NotFound(w, r)
			return
		}
		m := strings.ToValidUTF8(b, "\uFFFD")
		if r.Header.Get("Accept") == "application/vnd.github.raw" {
			_, _ = w.Write([]byte(m))
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"name": r.PathValue("name"), "type": "file", "size": len(b),
			"encoding": "base64", "content": base64.StdEncoding.EncodeToString([]byte(m))})
	}))
	mux.HandleFunc("GET /repos/hstin-de/otterlink/git/blobs/{sha}", auth(func(w http.ResponseWriter, r *http.Request) {
		for _, b := range updates {
			if blobSHA([]byte(b)) == r.PathValue("sha") && r.Header.Get("Accept") == "application/vnd.github.raw" {
				_, _ = w.Write([]byte(b))
				return
			}
		}
		http.NotFound(w, r)
	}))
	base = serve(t, mux)
	return base
}

// blobSHA is git's object id of a blob.
func blobSHA(b []byte) string {
	h := sha1.New()
	fmt.Fprintf(h, "blob %d\x00", len(b))
	h.Write(b)
	return hex.EncodeToString(h.Sum(nil))
}

// binarySig stands for an ed25519 signature: 64 bytes, most of them not UTF-8.
var binarySig = func() []byte {
	b := make([]byte, 64)
	for i := range b {
		b[i] = byte(0x80 + i)
	}
	return b
}()

func TestRepositories(t *testing.T) {
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("docker not found")
	}
	root := repoRoot()
	work := t.TempDir()
	must(t, os.Chmod(work, 0o777))
	ctx := filepath.Join(work, "ctx")
	must(t, os.MkdirAll(ctx, 0o755))
	must(t, os.WriteFile(filepath.Join(ctx, "Dockerfile"), []byte(toolsDockerfile), 0o644))
	docker(t, "build", "-q", "-t", toolsImage, ctx)

	must(t, os.MkdirAll(filepath.Join(work, "bin"), 0o755))
	must(t, os.WriteFile(filepath.Join(work, "bin", "pkg"), []byte("#!/bin/sh\necho test\n"), 0o755))
	docker(t, "run", "--rm", "--user", user(), "-e", "HOME=/work", "-v", work+":/work", toolsImage, "sh", "-c", `set -e
export GNUPGHOME=/work/gnupg; mkdir -p -m 700 $GNUPGHOME
gpg --batch --passphrase '' --quick-gen-key 'hstin test <test@example.com>' ed25519 sign never 2>/dev/null
gpg --batch --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}' > /work/fpr`)
	fprb, err := os.ReadFile(filepath.Join(work, "fpr"))
	must(t, err)
	fpr := strings.TrimSpace(string(fprb))

	// A copy of this repository with the test's projects.
	src := filepath.Join(work, "src")
	must(t, os.MkdirAll(src, 0o777))
	for _, d := range []string{"scripts", "site", "repo", "functions", "src", "wrangler.toml", "package.json", "package-lock.json"} {
		if out, err := exec.Command("cp", "-r", filepath.Join(root, d), src).CombinedOutput(); err != nil {
			t.Fatalf("cp: %v %s", err, out)
		}
	}
	must(t, os.WriteFile(filepath.Join(src, "projects.txt"), []byte("# test\notterlink hstin-de/otterlink\nsample hstin-de/sample\n"), 0o644))

	// The releases: otterlink with two packages over three releases (rpms
	// unsigned: pkgs signs them), a prerelease and a draft that stay out;
	// sample with a good release, one that carries a package of another name
	// and one whose digest does not match.
	ot := []string{"otterlink", "otterlink-server"}
	rels := []*release{
		{repo: "hstin-de/otterlink", tag: "v0.6.0", packages: ot},
		{repo: "hstin-de/otterlink", tag: "v0.7.3", packages: ot},
		{repo: "hstin-de/sample", tag: "v1.0.0", packages: []string{"sample"}},
		{repo: "hstin-de/otterlink", tag: "v0.8.0", packages: ot},
		{repo: "hstin-de/otterlink", tag: "v0.9.0-rc.1", packages: ot, pre: true},
		{repo: "hstin-de/otterlink", tag: "v1.0.0", packages: ot, draft: true},
		{repo: "hstin-de/sample", tag: "v1.1.0", packages: []string{"sample", "otterlink"}},
		{repo: "hstin-de/sample", tag: "v1.2.0", packages: []string{"sample"}, badDigest: true},
	}
	for _, rel := range rels {
		v := strings.TrimPrefix(rel.tag, "v")
		rel.dir = filepath.Join(work, "gh", rel.repo, rel.tag)
		must(t, os.MkdirAll(rel.dir, 0o777))
		for _, name := range rel.packages {
			for _, arch := range []string{"amd64", "arm64"} {
				formats := []string{"deb", "rpm", "archlinux"}
				if rel.pre || rel.draft {
					formats = formats[:2] // pkgver takes no "-"; these stay out anyway
				}
				for _, format := range formats {
					base := name + "_" + v + "_linux_" + arch
					ext := map[string]string{"deb": ".deb", "rpm": ".rpm", "archlinux": ".pkg.tar.zst"}[format]
					must(t, os.WriteFile(filepath.Join(work, base+".yaml"), []byte(nfpmConfig(name, arch, v)), 0o644))
					docker(t, "run", "--rm", "--user", user(), "-v", work+":/work", "-w", "/work", "goreleaser/nfpm:latest",
						"package", "-f", "/work/"+base+".yaml", "-p", format,
						"-t", "/work/gh/"+rel.repo+"/"+rel.tag+"/"+base+ext)
				}
			}
		}
		must(t, os.WriteFile(filepath.Join(rel.dir, "notes.txt"), []byte("release notes "+v), 0o644))
		must(t, os.WriteFile(filepath.Join(rel.dir, "page.html"), []byte("<script>alert(1)</script>"), 0o644))
	}
	gh := fakeGitHub(t, rels, map[string]string{
		// The manifest lists v0.6.0 (kept beyond KEEP below) and v0.5.0, which
		// is no published release.
		"stable.json":     `{"channel":"stable","releases":[{"version":"0.5.0"},{"version":"0.6.0"},{"version":"0.8.0"}]}`,
		"stable.json.sig": string(binarySig), "keys.json": `{"k":1}`, "keys.json.sig": string(binarySig),
	})

	tools := func(env []string, cmd ...string) (string, error) {
		args := []string{"run", "--rm", "--user", user(), "-e", "HOME=/work", "--network", "host", "-v", work + ":/work",
			"-e", "GNUPGHOME=/work/gnupg", "-e", "REPO_KEY=" + fpr, "-e", "STORE=/work/store",
			"-e", "GH_TOKEN=" + token, "-e", "GITHUB_API=" + gh}
		for _, e := range env {
			args = append(args, "-e", e)
		}
		out, err := exec.Command("docker", append(append(args, toolsImage), cmd...)...).CombinedOutput()
		return string(out), err
	}
	sync := func(env ...string) string {
		t.Helper()
		out, err := tools(append([]string{"ROOT=/work/src"}, env...), "/work/src/scripts/sync.sh", "/work/state")
		if err != nil {
			t.Fatalf("sync.sh: %v\n%s", err, out)
		}
		return out
	}
	out := sync()
	t.Logf("sync.sh:\n%s", out)
	for _, want := range []string{
		"otterlink v0.8.0: stored 18 files",
		`sample v1.1.0: otterlink_1.1.0_linux_amd64.deb is the package "otterlink"; sample may only publish sample and sample-*`,
		"sample v1.2.0: notes.txt does not match the digest GitHub recorded",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("sync.sh: missing %q", want)
		}
	}
	for _, bad := range []string{"v0.9.0-rc.1", "otterlink v1.0.0", "sample v1.1.0: stored", "sample v1.2.0: stored"} {
		if strings.Contains(out, bad) {
			t.Errorf("sync.sh took %q", bad)
		}
	}
	for _, f := range []string{"otterlink/v0.6.0/SHA256SUMS", "otterlink/v0.8.0/otterlink_0.8.0_linux_amd64.rpm",
		"otterlink/v0.8.0/otterlink_0.8.0_linux_arm64.pkg.tar.zst.sig", "sample/v1.0.0/SHA256SUMS", "state/projects/otterlink/updates/stable.json.sig"} {
		p := filepath.Join(work, "store", f)
		if strings.HasPrefix(f, "state/") {
			p = filepath.Join(work, f)
		}
		if _, err := os.Stat(p); err != nil {
			t.Errorf("missing %s", f)
		}
	}
	for _, f := range []string{"store/sample/v1.1.0", "store/sample/v1.2.0", "state/projects/sample/updates", "state/projects/otterlink/updates/README.md"} {
		if _, err := os.Stat(filepath.Join(work, f)); err == nil {
			t.Errorf("must not exist: %s", f)
		}
	}
	// The signatures arrive byte for byte.
	if b, err := os.ReadFile(filepath.Join(work, "state", "projects", "otterlink", "updates", "stable.json.sig")); err != nil || !bytes.Equal(b, binarySig) {
		t.Errorf("stable.json.sig changed on the way: %x (%v)", b, err)
	}
	// The rpms in the store carry the repository key's signature.
	if out, err := tools(nil, "sh", "-c", `set -e; gpg --batch --armor --export "$REPO_KEY" > /tmp/k.asc
rpmkeys --dbpath /tmp/db --import /tmp/k.asc
rpmkeys --dbpath /tmp/db --checksig /work/store/otterlink/v0.6.0/otterlink_0.6.0_linux_amd64.rpm`); err != nil || !strings.Contains(out, "signatures OK") {
		t.Errorf("stored rpm not signed: %v\n%s", err, out)
	}
	// Again: nothing new to store.
	if out := sync(); strings.Contains(out, "stored") {
		t.Errorf("second sync stored again:\n%s", out)
	}
	// A release stored before pkgs signed Arch packages gets the signatures.
	old := filepath.Join(work, "store", "otterlink", "v0.7.3")
	sums, err := os.ReadFile(filepath.Join(old, "SHA256SUMS"))
	must(t, err)
	var kept []string
	for _, l := range strings.Split(strings.TrimSpace(string(sums)), "\n") {
		if !strings.HasSuffix(l, ".sig") {
			kept = append(kept, l)
		}
	}
	must(t, os.WriteFile(filepath.Join(old, "SHA256SUMS"), []byte(strings.Join(kept, "\n")+"\n"), 0o644))
	matches, _ := filepath.Glob(filepath.Join(old, "*.sig"))
	for _, m := range matches {
		must(t, os.Remove(m))
	}
	if out := sync(); !strings.Contains(out, "otterlink v0.7.3: signed 4 Arch packages") || strings.Contains(out, "stored") {
		t.Errorf("signatures for a stored release:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(old, "otterlink-server_0.7.3_linux_amd64.pkg.tar.zst.sig")); err != nil {
		t.Error("no signature added")
	}

	// The site, from the state and the store.
	port := freePort(t)
	site := fmt.Sprintf("http://127.0.0.1:%d", port)
	out, err = tools([]string{"ROOT=/work/state", "PKGS_URL=" + site}, "/work/src/scripts/build.sh", "/work/src/out")
	if err != nil {
		t.Fatalf("build.sh: %v\n%s", err, out)
	}
	t.Logf("build.sh:\n%s", out)
	built := filepath.Join(src, "out")
	for _, f := range []string{"apt/dists/stable/InRelease", "rpm/repodata/repomd.xml.asc", "hstin-repo.deb",
		"hstin-repo.rpm", "hstin-repo.pkg.tar.zst", "arch/x86_64/hstin.db", "arch/x86_64/hstin.db.sig", "arch/aarch64/hstin.files.sig",
		"arch/x86_64/hstin-repo-1.0.0-1-any.pkg.tar.zst.sig", "arch/files.json", "otterlink/updates/stable.json.sig", "otterlink/index.html", "otterlink/latest.txt", "sample/index.html",
		"install.sh", "keys/hstin.gpg", "index.html"} {
		if _, err := os.Stat(filepath.Join(built, f)); err != nil {
			t.Errorf("site misses %s", f)
		}
	}
	for _, f := range []string{"sample/updates", "apt/pool", "rpm/pool", "rpm/hstin.repo"} {
		if _, err := os.Stat(filepath.Join(built, f)); err == nil {
			t.Errorf("site must not have %s", f)
		}
	}
	if b, _ := os.ReadFile(filepath.Join(built, "index.html")); !strings.Contains(string(b), fpr) {
		t.Error("the start page does not show the key's fingerprint")
	}
	if out, err := tools([]string{"ROOT=/work/state"}, "/work/src/scripts/build.sh", "/work/src/site"); err == nil {
		t.Errorf("build.sh accepted an output directory not named out:\n%s", out)
	}
	// A file in the store that no longer matches its SHA256SUMS stops the build.
	tampered := filepath.Join(work, "store", "otterlink", "v0.7.3", "otterlink_0.7.3_linux_amd64.deb")
	orig, err := os.ReadFile(tampered)
	must(t, err)
	must(t, os.WriteFile(tampered, append(slices.Clone(orig), 0), 0o644))
	if out, err := tools([]string{"ROOT=/work/state"}, "/work/src/scripts/build.sh", "/work/tmp/out"); err == nil ||
		!strings.Contains(out, "does not match its SHA256SUMS") {
		t.Errorf("build.sh signed a tampered file: %v\n%s", err, out)
	}
	must(t, os.WriteFile(tampered, orig, 0o644))

	// wrangler (from package-lock.json): the store into the local bucket (a
	// Workers config beside the Pages one: wrangler's r2 commands refuse Pages
	// projects), then pages dev with the functions and the bucket.
	seed := filepath.Join(work, "seed")
	must(t, os.MkdirAll(seed, 0o777))
	must(t, os.WriteFile(filepath.Join(seed, "wrangler.toml"), []byte(
		"name = \"seed\"\ncompatibility_date = \"2026-11-01\"\n[[r2_buckets]]\nbinding = \"DL\"\nbucket_name = \"hstin-pkgs\"\n"), 0o644))
	var puts []string
	must(t, filepath.Walk(filepath.Join(work, "store"), func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		key, _ := filepath.Rel(filepath.Join(work, "store"), p)
		puts = append(puts, fmt.Sprintf("$w r2 object put 'hstin-pkgs/%s' --file '/work/store/%s' --local --persist-to /work/wr > /dev/null", key, key))
		return nil
	}))
	script := "set -e\ncd /work/src && npm ci --silent --ignore-scripts --no-audit --no-fund > /dev/null\n" +
		"w=/work/src/node_modules/.bin/wrangler\ncd /work/seed\n" + strings.Join(puts, "\n") +
		fmt.Sprintf("\ncd /work/src\nexec $w pages dev --ip 127.0.0.1 --port %d --persist-to /work/wr\n", port)
	name := fmt.Sprintf("hstin-pkgs-e2e-%d", port)
	docker(t, "run", "-d", "--name", name, "--user", user(), "--network", "host", "-v", work+":/work",
		"-e", "HOME=/work", "-e", "npm_config_cache=/work/npm", "-e", "WRANGLER_SEND_METRICS=false", wranglerImage, "sh", "-c", script)
	t.Cleanup(func() {
		if t.Failed() {
			logs, _ := exec.Command("docker", "logs", "--tail", "60", name).CombinedOutput()
			t.Logf("wrangler:\n%s", logs)
		}
		_ = exec.Command("docker", "rm", "-f", name).Run()
	})
	deadline := time.Now().Add(10 * time.Minute)
	for {
		resp, err := http.Get(site + "/dl/otterlink/v0.8.0/notes.txt")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("wrangler did not serve the bucket: %v", err)
		}
		time.Sleep(2 * time.Second)
	}
	// A range of a release file, through the function.
	req, _ := http.NewRequest(http.MethodGet, site+"/dl/otterlink/v0.8.0/notes.txt", nil)
	req.Header.Set("Range", "bytes=8-12")
	if resp, err := http.DefaultClient.Do(req); err != nil || resp.StatusCode != http.StatusPartialContent {
		t.Errorf("range request: %v %v", resp, err)
	} else {
		resp.Body.Close()
	}
	for _, p := range []string{"/dl/otterlink/v0.8.0/missing.txt", "/hstin-repo.deb.sig", "/no/such/page"} {
		if resp, err := http.Get(site + p); err != nil || resp.StatusCode != http.StatusNotFound {
			t.Errorf("%s: %v %v", p, resp, err)
		} else {
			resp.Body.Close()
		}
	}
	// A release's HTML file is a download, not a page of the site.
	if resp, err := http.Get(site + "/dl/otterlink/v0.8.0/page.html"); err != nil {
		t.Error(err)
	} else {
		resp.Body.Close()
		if ct := resp.Header.Get("Content-Type"); ct != "application/octet-stream" || resp.Header.Get("Content-Security-Policy") == "" {
			t.Errorf("page.html served as %q", ct)
		}
	}
	if out, err := exec.Command(filepath.Join(root, "scripts", "check.sh"), site, built).CombinedOutput(); err != nil {
		t.Errorf("check.sh: %v\n%s", err, out)
	}

	t.Run("debian", func(t *testing.T) {
		out := docker(t, "run", "--rm", "--network", "host", "-e", "BASE="+site, "debian:trixie-slim", "sh", "-c", `set -e
apt-get update -qq && apt-get install -y -qq curl > /dev/null
cd "$(mktemp -d)" && curl -fsSLO $BASE/install.sh && sh install.sh otterlink
dpkg-query -W -f='installed ${Version}\n' otterlink
dpkg -L hstin-repo | grep -q /etc/apt/sources.list.d/hstin.sources && echo 'repo package'
apt-cache policy otterlink | grep -q ' 100 ' && echo 'pinned at 100'
apt-get install -y -qq --allow-downgrades otterlink=0.6.0 > /dev/null
dpkg-query -W -f='downgraded ${Version}\n' otterlink
apt-get install -y -qq otterlink otterlink-server sample > /dev/null
dpkg-query -W -f='${Package} ${Version}\n' otterlink otterlink-server sample`)
		for _, want := range []string{"installed 0.8.0", "repo package", "pinned at 100", "downgraded 0.6.0", "otterlink 0.8.0", "otterlink-server 0.8.0", "sample 1.0.0"} {
			if !strings.Contains(out, want) {
				t.Errorf("missing %q in:\n%s", want, out)
			}
		}
	})
	t.Run("debian package", func(t *testing.T) {
		out := docker(t, "run", "--rm", "--network", "host", "-e", "BASE="+site, "debian:trixie-slim", "sh", "-c", `set -e
apt-get update -qq && apt-get install -y -qq curl > /dev/null
cd "$(mktemp -d)" && curl -fsSLO $BASE/hstin-repo.deb && apt-get install -y -qq ./hstin-repo.deb > /dev/null && apt-get update -qq
apt-get install -y -qq sample > /dev/null
dpkg-query -W -f='${Package} ${Version}\n' sample`)
		if !strings.Contains(out, "sample 1.0.0") {
			t.Errorf("hstin-repo, then apt install:\n%s", out)
		}
	})
	t.Run("arch", func(t *testing.T) {
		// Only the hstin repository: pacman -Syu then upgrades nothing else.
		out := docker(t, "run", "--rm", "--network", "host", "-e", "BASE="+site, "-e", "FPR="+fpr, "archlinux:base", "sh", "-c", `set -e
sed -i '/^\[core\]/,$d' /etc/pacman.conf
pacman-key --init > /dev/null 2>&1
cd "$(mktemp -d)" && curl -fsSLO $BASE/install.sh && sh install.sh otterlink > /dev/null
pacman -Q otterlink hstin-repo
pacman-key --list-keys "$FPR" > /dev/null && echo 'key trusted'
grep -q '^Include = /etc/pacman.d/hstin-mirrorlist' /etc/pacman.conf && echo 'section added'
pacman -S --needed --noconfirm otterlink-server sample > /dev/null
pacman -Q otterlink-server sample
pacman -Rns --noconfirm otterlink otterlink-server sample > /dev/null
sed -i '/^\[hstin\]/,/^Include = \/etc\/pacman.d\/hstin-mirrorlist/d' /etc/pacman.conf
pacman -Rns --noconfirm hstin-repo > /dev/null
# The steps by hand, on a keyring without the key: pacman -U with the URL
# checks URL.sig, so the key is trusted first.
pacman-key --delete "$FPR" > /dev/null 2>&1
if pacman -U --noconfirm $BASE/hstin-repo.pkg.tar.zst > /dev/null 2>&1; then echo 'installed without the key'; fi
curl -fsSLo /tmp/hstin.asc $BASE/keys/hstin.asc
pacman-key --add /tmp/hstin.asc > /dev/null 2>&1 && pacman-key --lsign-key "$FPR" > /dev/null 2>&1
pacman -U --noconfirm $BASE/hstin-repo.pkg.tar.zst > /dev/null && echo 'by hand'`)
		for _, want := range []string{"otterlink 0.8.0-1", "hstin-repo 1.0.0-1", "key trusted", "section added", "otterlink-server 0.8.0-1", "sample 1.0.0-1", "by hand"} {
			if !strings.Contains(out, want) {
				t.Errorf("missing %q in:\n%s", want, out)
			}
		}
		if strings.Contains(out, "installed without the key") {
			t.Error("pacman -U URL installed hstin-repo without the key")
		}
	})
	t.Run("fedora", func(t *testing.T) {
		out := docker(t, "run", "--rm", "--network", "host", "-e", "BASE="+site, "fedora:42", "sh", "-c", `set -e
dnf install -y -q $BASE/hstin-repo.rpm
dnf install -y -q otterlink-server sample
rpm -q --qf 'installed %{NAME} %{VERSION}\n' otterlink-server sample
dnf install -y -q otterlink-0.6.0
rpm -q --qf 'pinned %{VERSION}\n' otterlink`)
		for _, want := range []string{"installed otterlink-server 0.8.0", "installed sample 1.0.0", "pinned 0.6.0"} {
			if !strings.Contains(out, want) {
				t.Errorf("missing %q in:\n%s", want, out)
			}
		}
	})

	// Pruning: with KEEP=1 the newest release stays, and v0.6.0 because the
	// update manifest lists it; v0.7.3 leaves the store.
	out = sync("KEEP=1")
	if !strings.Contains(out, "otterlink v0.7.3: removed") || strings.Contains(out, "otterlink v0.6.0: removed") {
		t.Errorf("prune:\n%s", out)
	}
	if !strings.Contains(out, "otterlink: the update metadata lists v0.5.0, which is no published release") {
		t.Errorf("no warning for v0.5.0:\n%s", out)
	}
	for tag, kept := range map[string]bool{"v0.6.0": true, "v0.7.3": false, "v0.8.0": true} {
		_, err := os.Stat(filepath.Join(work, "store", "otterlink", tag, "SHA256SUMS"))
		if (err == nil) != kept {
			t.Errorf("%s stored: %v, want %v", tag, err == nil, kept)
		}
	}
	// Releases that fail the checks do not push good ones out.
	if _, err := os.Stat(filepath.Join(work, "store", "sample", "v1.0.0", "SHA256SUMS")); err != nil {
		t.Error("sample v1.0.0 was removed")
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
