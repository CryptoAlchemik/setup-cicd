package state

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
)

func TestStoreSaveLoadReset(t *testing.T) {
	root := t.TempDir()
	store := New(root)
	cfg := &types.Config{
		Version: "1",
		RepoOwner: "alice",
		RepoName:  "app",
		RepoFull:  "alice/app",
		Stages: []types.Stage{{Name: "test", Host: "1.2.3.4", Port: 22}},
		PhaseStatus: map[string]bool{"3": true},
		Metadata: map[string]string{"x": "y"},
	}
	if err := store.Save(cfg); err != nil {
		t.Fatalf("save: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".cicd", "state.yaml")); err != nil {
		t.Fatalf("state file: %v", err)
	}
	loaded, err := store.Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if loaded.RepoFull != "alice/app" || len(loaded.Stages) != 1 {
		t.Fatalf("unexpected loaded config: %#v", loaded)
	}
	if err := store.Reset(); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".cicd", "state.yaml")); !os.IsNotExist(err) {
		t.Fatalf("state file still exists")
	}
}
