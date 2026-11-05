// Package e2e checks a site built by scripts/build.sh with real package
// managers: the site is built from signed test packages of two projects in a
// Debian container, a local server answers like Cloudflare Pages (files and
// _redirects) and another like the GitHub releases, and the install scripts,
// apt and dnf install from it in Debian and Fedora containers.
//
//	go test -count=1 -v ./e2e/
package e2e

import (
	"bufio"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const toolsImage = "hstin-pkgs-tools"

const toolsDockerfile = `FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends apt-utils createrepo-c rpm gnupg ca-certificates curl && rm -rf /var/lib/apt/lists/*
`

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

// pagesHandler serves dir like Cloudflare Pages: static _redirects lines
// first, then files.
func pagesHandler(dir string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if f, err := os.Open(filepath.Join(dir, "_redirects")); err == nil {
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				fields := strings.Fields(sc.Text())
				if len(fields) == 3 && fields[0] == r.URL.Path {
					f.Close()
					http.Redirect(w, r, fields[1], http.StatusFound)
					return
				}
			}
			f.Close()
		}
		http.FileServer(http.Dir(dir)).ServeHTTP(w, r)
	})
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

	// A copy of this repository with the test's projects: publish.sh (dry
	// run: no R2, no push) records the releases there, and the files go to
	// the test's dl.hstin.de by hand.
	src := filepath.Join(work, "src")
	must(t, os.MkdirAll(src, 0o777))
	for _, d := range []string{"scripts", "site"} {
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

	// Two projects: otterlink with two packages over three releases (the
	// oldest rpm unsigned) and update metadata, sample with one and none.
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
		must(t, os.WriteFile(filepath.Join(in, "files", "notes.txt"), []byte("not a package"), 0o644))
		if rel.project == "otterlink" {
			must(t, os.MkdirAll(filepath.Join(in, "updates"), 0o777))
			for _, n := range []string{"stable.json", "stable.json.sig", "keys.json", "keys.json.sig"} {
				must(t, os.WriteFile(filepath.Join(in, "updates", n), []byte("{\"v\":\""+rel.version+"\"}"), 0o644))
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
	if b, _ := os.ReadFile(filepath.Join(src, "projects", "otterlink", "releases", "v0.7.3.txt")); !strings.Contains(string(b), "notes.txt\notterlink-server_0.7.3_linux_amd64.deb") {
		t.Errorf("file list: %s", b)
	}

	dlURL := serve(t, http.FileServer(http.Dir(filepath.Join(work, "dl"))))
	siteDir := filepath.Join(work, "site")
	site := serve(t, pagesHandler(siteDir))
	fpr, err := os.ReadFile(filepath.Join(work, "fpr"))
	must(t, err)
	out := docker(t, "run", "--rm", "--user", user(), "-e", "HOME=/work", "--network", "host", "-v", work+":/work",
		"-e", "GNUPGHOME=/work/gnupg", "-e", "REPO_KEY="+strings.TrimSpace(string(fpr)), "-e", "ROOT=/work/src",
		"-e", "DL_URL="+dlURL, "-e", "PKGS_URL="+site, "-e", "CACHE=/work/cache",
		toolsImage, "/work/src/scripts/build.sh", "/work/site")
	t.Logf("build.sh:\n%s", out)
	if !strings.Contains(out, "otterlink otterlink_0.6.0_linux_amd64.rpm is not signed") {
		t.Error("the unsigned rpm was not left out")
	}
	for _, f := range []string{"apt/dists/stable/InRelease", "apt/otterlink.sources", "apt/sample.sources",
		"rpm/otterlink/repodata/repomd.xml.asc", "rpm/sample/sample.repo", "otterlink/updates/stable.json.sig",
		"otterlink/install.sh", "sample/install.sh", "keys/hstin.gpg", "index.html", "otterlink/index.html"} {
		if _, err := os.Stat(filepath.Join(siteDir, f)); err != nil {
			t.Errorf("site misses %s", f)
		}
	}
	if _, err := os.Stat(filepath.Join(siteDir, "sample", "updates")); err == nil {
		t.Error("sample has no update metadata")
	}
	if _, err := os.Stat(filepath.Join(siteDir, "apt", "pool")); err == nil {
		t.Error("the site must not carry packages")
	}
	if b, _ := os.ReadFile(filepath.Join(siteDir, "otterlink", "index.html")); !strings.Contains(string(b), dlURL+"/otterlink/v0.8.0/notes.txt") {
		t.Errorf("the download page does not list the latest files:\n%s", b)
	}
	// Pruning: with KEEP=2 the oldest release goes from R2 and the lists.
	out = publish([]string{"KEEP=2"}, "otterlink", filepath.Join(work, "in", "otterlink", "v0.8.0"))
	if !strings.Contains(out, "dry run: aws s3 rm s3://hstin-dl/otterlink/v0.6.0/ --recursive") || !strings.Contains(out, "removed otterlink v0.6.0") {
		t.Errorf("prune:\n%s", out)
	}
	defer func() {
		if _, err := os.Stat(filepath.Join(src, "projects", "otterlink", "releases", "v0.6.0.txt")); err == nil {
			t.Error("v0.6.0 is still listed")
		}
	}()

	t.Run("debian", func(t *testing.T) {
		out := docker(t, "run", "--rm", "--network", "host", "-e", "BASE="+site, "debian:trixie-slim", "sh", "-c", `set -e
apt-get update -qq && apt-get install -y -qq curl > /dev/null
curl -fsSL $BASE/otterlink/install.sh | sh
dpkg-query -W -f='installed ${Version}\n' otterlink
apt-get install -y -qq --allow-downgrades otterlink=0.6.0 > /dev/null
dpkg-query -W -f='downgraded ${Version}\n' otterlink
apt-get install -y -qq otterlink otterlink-server > /dev/null
dpkg-query -W -f='${Package} ${Version}\n' otterlink otterlink-server
if apt-get install -y -qq hstin-sample > /dev/null 2>&1; then echo 'sample without its component'; fi
curl -fsSL $BASE/sample/install.sh | sh -s -- hstin-sample > /dev/null
dpkg-query -W -f='${Package} ${Version}\n' hstin-sample`)
		for _, want := range []string{"installed 0.8.0", "downgraded 0.6.0", "otterlink 0.8.0", "otterlink-server 0.8.0", "hstin-sample 1.0.0"} {
			if !strings.Contains(out, want) {
				t.Errorf("missing %q in:\n%s", want, out)
			}
		}
		if strings.Contains(out, "sample without its component") {
			t.Error("the otterlink component must not carry the sample")
		}
	})
	t.Run("fedora", func(t *testing.T) {
		out := docker(t, "run", "--rm", "--network", "host", "-e", "BASE="+site, "fedora:42", "sh", "-c", `set -e
curl -fsSL $BASE/otterlink/install.sh | sh -s -- otterlink-server
rpm -q --qf 'installed %{VERSION}\n' otterlink-server
dnf install -y -q otterlink-0.7.3
rpm -q --qf 'pinned %{VERSION}\n' otterlink
if dnf install -y -q otterlink-0.6.0 2>/dev/null; then echo 'unsigned installed'; fi
if dnf install -y -q hstin-sample 2>/dev/null; then echo 'sample without its repository'; fi`)
		for _, want := range []string{"installed 0.8.0", "pinned 0.7.3"} {
			if !strings.Contains(out, want) {
				t.Errorf("missing %q in:\n%s", want, out)
			}
		}
		for _, bad := range []string{"unsigned installed", "sample without its repository"} {
			if strings.Contains(out, bad) {
				t.Error(bad)
			}
		}
	})
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
