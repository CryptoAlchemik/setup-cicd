package project

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDetect(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".git"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".git", "config"), []byte("[remote \"origin\"]\n\turl = https://github.com/acme/app.git\n"), 0644); err != nil {
		t.Fatal(err)
	}
	info, err := Detect(root)
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	if info.Full != "acme/app" {
		t.Fatalf("unexpected repo: %#v", info)
	}
}

func TestEnsureGitignoreAndDockerignore(t *testing.T) {
	root := t.TempDir()
	if err := EnsureGitignore(root); err != nil {
		t.Fatalf("gitignore: %v", err)
	}
	data, _ := os.ReadFile(filepath.Join(root, ".gitignore"))
	if !strings.Contains(string(data), ".cicd/") {
		t.Fatalf("missing .cicd entry: %s", string(data))
	}
	if err := Dockerignore(root); err != nil {
		t.Fatalf("dockerignore: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".dockerignore")); err != nil {
		t.Fatalf("dockerignore file missing: %v", err)
	}
}
