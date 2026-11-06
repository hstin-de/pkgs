// Package e2e checks pkgs.hstin.de end to end: signed test packages of two
// projects are published (scripts/publish.sh, dry run) into a local R2
// bucket, the site is built (scripts/build.sh) and served by `wrangler pages
// dev` with its functions and the bucket, and hstin-repo, the install script,
// apt and dnf install from it in Debian and Fedora containers.
//
//	go test -count=1 -v ./e2e/
package e2e

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

const toolsImage = "hstin-pkgs-tools"

const toolsDockerfile = `FROM goreleaser/nfpm:latest AS nfpm
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends apt-utils createrepo-c rpm gnupg ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY --from=nfpm /usr/bin/nfpm /usr/bin/nfpm
`

// wranglerImage runs wrangler (node and the npm cache in the test directory).
const wranglerImage = "node:22"

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

func nfpmConfig(name, arch, v, key string) string {
	c := "name: " + name + "\narch: " + arch + "\nplatform: linux\nversion: " + v + `
maintainer: test <test@example.com>
description: test package
license: Apache-2.0
contents:
  - src: /work/bin/pkg
    dst: /usr/bin/` + name + `
    file_info: {mode: 0755}
`
	if key != "" {
		c += "rpm:\n  signature:\n    key_file: " + key + "\n"
	}
	return c
}

type release struct {
	project, version string
	packages         []string
	signed           bool
}

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
gpg --batch --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}' > /work/fpr
gpg --batch --armor --export-secret-keys > /work/key.asc`)
	fpr, err := os.ReadFile(filepath.Join(work, "fpr"))
	must(t, err)

	// A copy of this repository with the test's projects: publish.sh (dry
	// run: no R2, no push) records the releases there; the files go into the
	// local bucket below.
	src := filepath.Join(work, "src")
	must(t, os.MkdirAll(src, 0o777))
	for _, d := range []string{"scripts", "site", "repo", "functions", "src", "wrangler.toml"} {
		if out, err := exec.Command("cp", "-r", filepath.Join(root, d), src).CombinedOutput(); err != nil {
			t.Fatalf("cp: %v %s", err, out)
		}
	}
	must(t, os.WriteFile(filepath.Join(src, "projects.txt"), []byte("# test\notterlink\nsample\n"), 0o644))
	git := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", src, "-c", "user.name=t", "-c", "user.email=t@e"}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	git("init", "-q", "-b", "main")
	git("add", "-A")
	git("commit", "-qm", "test")
	publish := func(env []string, args ...string) string {
		t.Helper()
		cmd := exec.Command(filepath.Join(src, "scripts", "publish.sh"), args...)
		cmd.Env = append(os.Environ(), append([]string{"DRY_RUN=1"}, env...)...)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("publish.sh %v: %v\n%s", args, err, out)
		}
		return string(out)
	}

	// Two projects in one repository: otterlink with two packages over
	// three releases (the oldest rpm unsigned) and update metadata, sample
	// with one and none.
	ot := []string{"otterlink", "otterlink-server"}
	for _, rel := range []release{
		{"otterlink", "0.6.0", ot, false}, {"otterlink", "0.7.3", ot, true}, {"otterlink", "0.8.0", ot, true},
		{"sample", "1.0.0", []string{"hstin-sample"}, true},
	} {
		in := filepath.Join(work, "in", rel.project, "v"+rel.version)
		must(t, os.MkdirAll(filepath.Join(in, "files"), 0o777))
		key := "/work/key.asc"
		if !rel.signed {
			key = ""
		}
		for _, name := range rel.packages {
			for _, arch := range []string{"amd64", "arm64"} {
				for _, format := range []string{"deb", "rpm"} {
					base := name + "_" + rel.version + "_linux_" + arch
					must(t, os.WriteFile(filepath.Join(work, base+".yaml"), []byte(nfpmConfig(name, arch, rel.version, key)), 0o644))
					docker(t, "run", "--rm", "--user", user(), "-v", work+":/work", "-w", "/work", "goreleaser/nfpm:latest",
						"package", "-f", "/work/"+base+".yaml", "-p", format,
						"-t", "/work/in/"+rel.project+"/v"+rel.version+"/files/"+base+"."+format)
				}
			}
		}
		must(t, os.WriteFile(filepath.Join(in, "files", "notes.txt"), []byte("release notes "+rel.version), 0o644))
		if rel.project == "otterlink" {
			must(t, os.MkdirAll(filepath.Join(in, "updates"), 0o777))
			for _, n := range []string{"stable.json", "stable.json.sig", "keys.json", "keys.json.sig"} {
				must(t, os.WriteFile(filepath.Join(in, "updates", n), []byte(`{"v":"`+rel.version+`"}`), 0o644))
			}
		}
		out := publish(nil, rel.project, "v"+rel.version, in)
		if !strings.Contains(out, "dry run: aws s3 cp "+in+"/files/ s3://hstin-dl/"+rel.project+"/v"+rel.version+"/") {
			t.Errorf("publish.sh did not upload:\n%s", out)
		}
		dl := filepath.Join(work, "dl", rel.project, "v"+rel.version)
		must(t, os.MkdirAll(filepath.Dir(dl), 0o777))
		must(t, os.Rename(filepath.Join(in, "files"), dl))
	}
	if b, _ := os.ReadFile(filepath.Join(src, "projects", "otterlink", "updates", "stable.json")); !strings.Contains(string(b), "0.8.0") {
		t.Errorf("update metadata not taken over: %s", b)
	}

	// The site, built against the files (build.sh reads them over HTTP here,
	// from R2 in the deploy).
	port := freePort(t)
	site := fmt.Sprintf("http://127.0.0.1:%d", port)
	dlURL := serve(t, http.FileServer(http.Dir(filepath.Join(work, "dl"))))
	out := docker(t, "run", "--rm", "--user", user(), "-e", "HOME=/work", "--network", "host", "-v", work+":/work",
		"-e", "GNUPGHOME=/work/gnupg", "-e", "REPO_KEY="+strings.TrimSpace(string(fpr)), "-e", "ROOT=/work/src",
		"-e", "DL_URL="+dlURL, "-e", "PKGS_URL="+site, "-e", "CACHE=/work/cache",
		toolsImage, "/work/src/scripts/build.sh", "/work/src/out")
	t.Logf("build.sh:\n%s", out)
	if !strings.Contains(out, "otterlink otterlink_0.6.0_linux_amd64.rpm is not signed") {
		t.Error("the unsigned rpm was not left out")
	}
	built := filepath.Join(src, "out")
	for _, f := range []string{"apt/dists/stable/InRelease", "rpm/repodata/repomd.xml.asc", "rpm/hstin.repo", "hstin-repo.deb",
		"hstin-repo.rpm", "otterlink/updates/stable.json.sig", "otterlink/index.html", "sample/index.html", "install.sh",
		"keys/hstin.gpg", "index.html"} {
		if _, err := os.Stat(filepath.Join(built, f)); err != nil {
			t.Errorf("site misses %s", f)
		}
	}
	for _, f := range []string{"sample/updates", "apt/pool", "rpm/pool", "_redirects"} {
		if _, err := os.Stat(filepath.Join(built, f)); err == nil {
			t.Errorf("site must not have %s", f)
		}
	}
	if b, _ := os.ReadFile(filepath.Join(built, "index.html")); !strings.Contains(string(b), strings.TrimSpace(string(fpr))) {
		t.Error("the start page does not show the key's fingerprint")
	}

	// wrangler: the files into the local bucket (a Workers config beside
	// the Pages one: wrangler's r2 commands refuse Pages projects), then
	// pages dev with the functions and the bucket.
	seed := filepath.Join(work, "seed")
	must(t, os.MkdirAll(seed, 0o777))
	must(t, os.WriteFile(filepath.Join(seed, "wrangler.toml"), []byte(
		"name = \"seed\"\ncompatibility_date = \"2026-11-01\"\n[[r2_buckets]]\nbinding = \"DL\"\nbucket_name = \"hstin-dl\"\n"), 0o644))
	var puts []string
	must(t, filepath.Walk(filepath.Join(work, "dl"), func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		key, _ := filepath.Rel(filepath.Join(work, "dl"), p)
		puts = append(puts, fmt.Sprintf("$w r2 object put 'hstin-dl/%s' --file '/work/dl/%s' --local --persist-to /work/wr > /dev/null", key, key))
		return nil
	}))
	script := "set -e\nmkdir -p /work/tool && cd /work/tool && npm install --silent --no-audit --no-fund wrangler@4 > /dev/null\n" +
		"w=/work/tool/node_modules/.bin/wrangler\ncd /work/seed\n" + strings.Join(puts, "\n") +
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
	if resp, err := http.Get(site + "/dl/otterlink/v0.8.0/missing.txt"); err != nil || resp.StatusCode != http.StatusNotFound {
		t.Errorf("a missing file: %v %v", resp, err)
	}

	t.Run("debian", func(t *testing.T) {
		out := docker(t, "run", "--rm", "--network", "host", "-e", "BASE="+site, "debian:trixie-slim", "sh", "-c", `set -e
apt-get update -qq && apt-get install -y -qq curl > /dev/null
cd /tmp && curl -fsSLO $BASE/install.sh && sh install.sh otterlink
dpkg-query -W -f='installed ${Version}\n' otterlink
dpkg -L hstin-repo | grep -q /etc/apt/sources.list.d/hstin.sources && echo 'repo package'
apt-get install -y -qq --allow-downgrades otterlink=0.6.0 > /dev/null
dpkg-query -W -f='downgraded ${Version}\n' otterlink
apt-get install -y -qq otterlink otterlink-server hstin-sample > /dev/null
dpkg-query -W -f='${Package} ${Version}\n' otterlink otterlink-server hstin-sample`)
		for _, want := range []string{"installed 0.8.0", "repo package", "downgraded 0.6.0", "otterlink 0.8.0", "otterlink-server 0.8.0", "hstin-sample 1.0.0"} {
			if !strings.Contains(out, want) {
				t.Errorf("missing %q in:\n%s", want, out)
			}
		}
	})
	t.Run("debian package", func(t *testing.T) {
		out := docker(t, "run", "--rm", "--network", "host", "-e", "BASE="+site, "debian:trixie-slim", "sh", "-c", `set -e
apt-get update -qq && apt-get install -y -qq curl > /dev/null
curl -fsSLo /tmp/hstin-repo.deb $BASE/hstin-repo.deb
apt-get install -y -qq /tmp/hstin-repo.deb > /dev/null && apt-get update -qq
apt-get install -y -qq hstin-sample > /dev/null
dpkg-query -W -f='${Package} ${Version}\n' hstin-sample`)
		if !strings.Contains(out, "hstin-sample 1.0.0") {
			t.Errorf("hstin-repo, then apt install:\n%s", out)
		}
	})
	t.Run("fedora", func(t *testing.T) {
		out := docker(t, "run", "--rm", "--network", "host", "-e", "BASE="+site, "fedora:42", "sh", "-c", `set -e
dnf install -y -q $BASE/hstin-repo.rpm
dnf install -y -q otterlink-server hstin-sample
rpm -q --qf 'installed %{NAME} %{VERSION}\n' otterlink-server hstin-sample
dnf install -y -q otterlink-0.7.3
rpm -q --qf 'pinned %{VERSION}\n' otterlink
if dnf install -y -q otterlink-0.6.0 2>/dev/null; then echo 'unsigned installed'; fi`)
		for _, want := range []string{"installed otterlink-server 0.8.0", "installed hstin-sample 1.0.0", "pinned 0.7.3"} {
			if !strings.Contains(out, want) {
				t.Errorf("missing %q in:\n%s", want, out)
			}
		}
		if strings.Contains(out, "unsigned installed") {
			t.Error("dnf installed the unsigned 0.6.0")
		}
	})

	// Pruning: with KEEP=2 the oldest release goes from R2 and the lists.
	out = publish([]string{"KEEP=2"}, "otterlink", filepath.Join(work, "in", "otterlink", "v0.8.0"))
	if !strings.Contains(out, "dry run: aws s3 rm s3://hstin-dl/otterlink/v0.6.0/ --recursive") || !strings.Contains(out, "removed otterlink v0.6.0") {
		t.Errorf("prune:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(src, "projects", "otterlink", "releases", "v0.6.0.txt")); err == nil {
		t.Error("v0.6.0 is still listed")
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
