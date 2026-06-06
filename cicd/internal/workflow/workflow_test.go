package workflow

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
)

func TestGenerateWorkflow(t *testing.T) {
	root := t.TempDir()
	g := New(root)
	out, err := g.Generate(&types.Config{
		RepoName: "app",
		RepoOwner: "acme",
		Stages: []types.Stage{{Name: "test", Branch: "develop"}, {Name: "prod", Branch: "main"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if out != filepath.Join(root, ".github/workflows/pipeline.yml") {
		t.Fatalf("unexpected out path: %s", out)
	}
	data, _ := os.ReadFile(out)
	content := string(data)
	if !strings.Contains(content, "deploy-test") || !strings.Contains(content, "deploy-prod") {
		t.Fatalf("workflow missing jobs: %s", content)
	}
}
