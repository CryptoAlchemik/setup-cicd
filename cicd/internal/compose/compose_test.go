package compose

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/CryptoAlchemik/setup-cicd/cicd/internal/ssh"
	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
)

func TestGenerateMinimalAndTransform(t *testing.T) {
	root := t.TempDir()
	g := New(ssh.NewWithRunner(&sshRunner{}), root)
	cfg := &types.Config{RepoOwner: "acme", RepoName: "app"}
	stage := types.Stage{Name: "test"}
	out, err := g.Generate(stage, cfg)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(out)
	if !strings.Contains(string(data), "image: ghcr.io/acme/app:test-latest") {
		t.Fatalf("unexpected compose: %s", string(data))
	}
}

func TestUploadUsesRepoDir(t *testing.T) {
	root := t.TempDir()
	_ = os.WriteFile(filepath.Join(root, "docker-compose.test.yml"), []byte("x"), 0644)
	g := New(ssh.NewWithRunner(&sshRunner{}), root)
	if err := g.Upload("repo", types.Stage{Name: "test", Host: "1.2.3.4", Port: 22}); err != nil {
		t.Fatal(err)
	}
}

type sshRunner struct{}

func (sshRunner) CombinedOutput(name string, args ...string) ([]byte, error) { return []byte(""), nil }
