package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInitAndPaths(t *testing.T) {
	root := t.TempDir()
	if err := Init(root); err != nil {
		t.Fatalf("init: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, CICDDir)); err != nil {
		t.Fatalf(".cicd dir missing: %v", err)
	}
	if got := LocalEnvPath(root, "test"); got != filepath.Join(root, CICDDir, ".env.test") {
		t.Fatalf("local env path: %s", got)
	}
	if got := SSHKeyPath(root, "repo", "test"); got == "" {
		t.Fatal("ssh key path empty")
	}
	if got := DeployDir("repo"); got != "/opt/repo" {
		t.Fatalf("deploy dir: %s", got)
	}
}
