package nginx

import (
	"strings"
	"testing"

	"github.com/CryptoAlchemik/setup-cicd/cicd/internal/ssh"
	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
)

type runner struct{ calls []string }

func (r *runner) CombinedOutput(name string, args ...string) ([]byte, error) {
	r.calls = append(r.calls, name+" "+strings.Join(args, " "))
	return []byte("ok"), nil
}

func TestListenDirectives(t *testing.T) {
	s := New(ssh.NewWithRunner(&runner{}))
	if got := s.listenDirectives(80); !strings.Contains(got, "listen 80;") {
		t.Fatalf("unexpected: %s", got)
	}
}

func TestConfigureAndVerify(t *testing.T) {
	r := &runner{}
	s := New(ssh.NewWithRunner(r))
	stage := types.Stage{Name: "test", Host: "1.2.3.4", Port: 22}
	if err := s.Configure(stage, types.NginxOptions{Domain: "example.com", ExternalPort: 8080, AppPort: 8000}); err != nil {
		t.Fatal(err)
	}
	if len(r.calls) == 0 {
		t.Fatal("expected ssh calls")
	}
	if _, err := s.VerifyHealth(stage, 8000); err != nil {
		t.Fatal(err)
	}
}
