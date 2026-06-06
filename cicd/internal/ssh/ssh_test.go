package ssh

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakeRunner struct {
	calls []string
	resp  string
	err   error
}

func (f *fakeRunner) CombinedOutput(name string, args ...string) ([]byte, error) {
	f.calls = append(f.calls, name+" "+strings.Join(args, " "))
	if name == "ssh-keygen" {
		for i := 0; i < len(args)-1; i++ {
			if args[i] == "-f" {
				priv := args[i+1]
				_ = os.MkdirAll(filepath.Dir(priv), 0700)
				_ = os.WriteFile(priv, []byte("priv"), 0600)
				_ = os.WriteFile(priv+".pub", []byte("pub"), 0644)
			}
		}
	}
	return []byte(f.resp), f.err
}

func TestRunAndCopyBuildCommands(t *testing.T) {
	r := &fakeRunner{}
	c := NewWithRunner(r)
	_, _ = c.Run(SSHAuth{Host: "1.2.3.4", Port: 22, KeyPath: "/key"}, "echo ok")
	_, _ = c.Copy(SSHAuth{Host: "1.2.3.4", Port: 22, KeyPath: "/key"}, "src", "dst")
	if len(r.calls) != 2 {
		t.Fatalf("calls: %#v", r.calls)
	}
	if !strings.Contains(r.calls[0], "root@1.2.3.4 echo ok") {
		t.Fatalf("run call wrong: %s", r.calls[0])
	}
	if !strings.Contains(r.calls[1], "scp") {
		t.Fatalf("copy call wrong: %s", r.calls[1])
	}
}

func TestGenerateKeyPair(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	r := &fakeRunner{}
	c := NewWithRunner(r)
	kp, err := c.GenerateKeyPair("cicd_repo_test", "cicd-test")
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	if kp.PrivateKey == "" || kp.PublicKey == "" {
		t.Fatal("missing key paths")
	}
	if _, err := os.Stat(kp.PrivateKey); err != nil {
		t.Fatalf("private key missing: %v", err)
	}
	if _, err := os.Stat(kp.PublicKey); err != nil {
		t.Fatalf("public key missing: %v", err)
	}
	if !strings.Contains(r.calls[0], "ssh-keygen") {
		t.Fatalf("unexpected call: %s", r.calls[0])
	}
	_ = fmt.Sprint(kp)
}
