package nginx

import (
	"fmt"
	"os"
	"path/filepath"
	"text/template"
	"strings"

	ctpl "github.com/CryptoAlchemik/setup-cicd/cicd/internal/templates"
	"github.com/CryptoAlchemik/setup-cicd/cicd/internal/ssh"
	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
)

type Setup struct {
	ssh *ssh.Client
}

func New(s *ssh.Client) *Setup {
	return &Setup{ssh: s}
}

func (n *Setup) Configure(stage types.Stage, opts types.NginxOptions) error {
	auth := ssh.SSHAuth{
		Host:     stage.Host,
		Port:     stage.Port,
		KeyPath:  stage.RootKeyPath,
		Password: stage.RootPass,
	}

	// install nginx if needed
	out, err := n.ssh.Run(auth, "apt-get update -qq && apt-get install -y -qq nginx 2>&1")
	if err != nil {
		return fmt.Errorf("install nginx: %w: %s", err, out)
	}

	tplBytes, err := ctpl.FS.ReadFile("nginx.tmpl")
	if err != nil {
		return err
	}
	tpl, err := template.New("nginx").Parse(string(tplBytes))
	if err != nil {
		return err
	}
	tmp := filepath.Join(os.TempDir(), "nginx-app.conf")
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	data := struct {
		Listen  string
		Domain  string
		AppPort int
	}{
		Listen:  n.listenDirectives(opts.ExternalPort),
		Domain:  opts.Domain,
		AppPort: opts.AppPort,
	}
	if err := tpl.Execute(f, data); err != nil {
		f.Close()
		return err
	}
	f.Close()
	if _, err := os.ReadFile(tmp); err != nil {
		return err
	}
	_, err = n.ssh.Copy(auth, tmp, "/etc/nginx/sites-available/app")
	if err != nil {
		return fmt.Errorf("copy nginx config: %w", err)
	}
	defer os.Remove(tmp)

	_, err = n.ssh.Run(auth, "ln -sf /etc/nginx/sites-available/app /etc/nginx/sites-enabled/app")
	if err != nil {
		return fmt.Errorf("enable nginx site: %w", err)
	}

	// check for default conflicts
	portStr := fmt.Sprintf("%d", opts.ExternalPort)
	_, _ = n.ssh.Run(auth, fmt.Sprintf(
		"grep -q 'listen %s.*default_server' /etc/nginx/sites-enabled/default 2>/dev/null && rm -f /etc/nginx/sites-enabled/default || true", portStr,
	))

	// test and reload
	out, err = n.ssh.Run(auth, "nginx -t")
	if err != nil {
		return fmt.Errorf("nginx test: %w: %s", err, out)
	}

	_, err = n.ssh.Run(auth, "systemctl enable nginx && systemctl reload nginx")
	if err != nil {
		return fmt.Errorf("nginx reload: %w", err)
	}

	return nil
}

func (n *Setup) SSL(stage types.Stage, domain string) error {
	auth := ssh.SSHAuth{
		Host:     stage.Host,
		Port:     stage.Port,
		KeyPath:  stage.RootKeyPath,
		Password: stage.RootPass,
	}

	out, err := n.ssh.Run(auth, fmt.Sprintf(
		"apt-get install -y -qq certbot python3-certbot-nginx && certbot --nginx -d %s --non-interactive --agree-tos -m admin@%s --redirect",
		domain, domain,
	))
	if err != nil {
		return fmt.Errorf("certbot: %w: %s", err, out)
	}
	return nil
}

func (n *Setup) listenDirectives(port int) string {
	switch port {
	case 80:
		return "    listen 80;\n    listen [::]:80;"
	case 443:
		return "    listen 443 ssl;\n    listen [::]:443 ssl;"
	default:
		return fmt.Sprintf("    listen %d;\n    listen [::]:%d;", port, port)
	}
}

// VerifyHealth checks application via SSH-local curl
func (n *Setup) VerifyHealth(stage types.Stage, appPort int) (string, error) {
	auth := ssh.SSHAuth{
		Host:     stage.Host,
		Port:     stage.Port,
		KeyPath:  stage.RootKeyPath,
		Password: stage.RootPass,
	}
	out, err := n.ssh.Run(auth, fmt.Sprintf(
		"curl -s -o /dev/null -w '%%{http_code}' --max-time 5 http://localhost:%d/health", appPort,
	))
	return strings.TrimSpace(out), err
}
