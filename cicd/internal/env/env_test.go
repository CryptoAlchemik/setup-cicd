package env

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/CryptoAlchemik/setup-cicd/cicd/internal/ssh"
	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
)

func TestLoadExampleAndSave(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".env.example"), []byte("A=1\n# x\nB=2\n"), 0644); err != nil {
		t.Fatal(err)
	}
	c := New(ssh.NewWithRunner(&sshTestRunner{}), root)
	env, err := c.LoadExample()
	if err != nil {
		t.Fatal(err)
	}
	if env.Values["A"] != "1" || env.Values["B"] != "2" {
		t.Fatalf("unexpected env: %#v", env.Values)
	}
	if err := c.Save("test", env); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, ".cicd", ".env.test")); err != nil {
		t.Fatal(err)
	}
}

func TestUploadBuildsPaths(t *testing.T) {
	root := t.TempDir()
	c := New(ssh.NewWithRunner(&sshTestRunner{}), root)
	env := &types.Env{Values: map[string]string{"A": "1"}}
	if err := c.Save("test", env); err != nil {
		t.Fatal(err)
	}
	if err := c.Upload("repo", types.Stage{Name: "test", Host: "1.2.3.4", Port: 22}, env); err != nil {
		t.Fatal(err)
	}
}

type sshTestRunner struct{}

func (sshTestRunner) CombinedOutput(name string, args ...string) ([]byte, error) { return []byte(""), nil }
