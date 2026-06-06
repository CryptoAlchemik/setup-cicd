package github

import (
	"strings"
	"testing"

	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
)

type fakeGH struct{ calls []string }

func (f *fakeGH) CombinedOutput(name string, args ...string) ([]byte, error) {
	f.calls = append(f.calls, name+" "+strings.Join(args, " "))
	return []byte("ok"), nil
}
func (f *fakeGH) Output(name string, args ...string) ([]byte, error) {
	f.calls = append(f.calls, name+" "+strings.Join(args, " "))
	return []byte("123"), nil
}
func (f *fakeGH) Run(name string, args ...string) error {
	f.calls = append(f.calls, name+" "+strings.Join(args, " "))
	return nil
}

func TestSecretAndWorkflowHelpers(t *testing.T) {
	f := &fakeGH{}
	c := NewWithRunner("acme/app", f)
	if err := c.SetSecret("SSH_HOST_TEST", "1.2.3.4"); err != nil {
		t.Fatal(err)
	}
	if _, err := c.TriggerWorkflow("pipeline.yml", "main"); err != nil {
		t.Fatal(err)
	}
	if _, err := c.GetLastRunID("pipeline.yml"); err != nil {
		t.Fatal(err)
	}
	if err := c.SetupSecrets(types.Stage{Name: "test", Host: "1.2.3.4"}, "priv"); err != nil {
		t.Fatal(err)
	}
}
