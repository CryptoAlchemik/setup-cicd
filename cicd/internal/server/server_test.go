package server

import (
	"os"
	"strings"
	"testing"

	"github.com/CryptoAlchemik/setup-cicd/cicd/internal/ssh"
	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
)

type fakeRunner struct{ calls []string }

func (f *fakeRunner) CombinedOutput(name string, args ...string) ([]byte, error) {
	f.calls = append(f.calls, name+" "+strings.Join(args, " "))
	return []byte("ok"), nil
}

func TestProvisionAndVerifyBuildCommands(t *testing.T) {
	r := &fakeRunner{}
	client := ssh.NewWithRunner(r)
	prov := New(client)
	key := t.TempDir() + "/deploy.pub"
	if err := os.WriteFile(key, []byte("ssh-ed25519 AAAA test"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := prov.Provision("app", types.Stage{Name: "test", Host: "1.2.3.4", Port: 22, RootKeyPath: "/root/key"}, &types.SSHKeyPair{PublicKey: key}); err != nil {
		t.Fatal(err)
	}
	if err := prov.Verify(types.Stage{Name: "test", Host: "1.2.3.4", Port: 22, RootKeyPath: "/root/key"}); err != nil {
		t.Fatal(err)
	}
	if len(r.calls) == 0 {
		t.Fatal("expected ssh calls")
	}
}
