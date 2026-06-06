package env

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/CryptoAlchemik/setup-cicd/cicd/internal/ssh"
	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
)

type Collector struct {
	ssh         *ssh.Client
	projectRoot string
	cicdDir     string
}

func New(s *ssh.Client, projectRoot string) *Collector {
	return &Collector{
		ssh:         s,
		projectRoot: projectRoot,
		cicdDir:     filepath.Join(projectRoot, ".cicd"),
	}
}

func (c *Collector) LoadExample() (*types.Env, error) {
	path := filepath.Join(c.projectRoot, ".env.example")
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	env := &types.Env{Values: make(map[string]string)}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			env.Values[parts[0]] = parts[1]
		}
	}
	return env, nil
}

func (c *Collector) Save(stage string, env *types.Env) error {
	dir := c.cicdDir
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	path := filepath.Join(dir, fmt.Sprintf(".env.%s", stage))
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	for k, v := range env.Values {
		if _, err := fmt.Fprintf(f, "%s=%s\n", k, v); err != nil {
			return err
		}
	}
	return nil
}

func (c *Collector) Upload(repoName string, stage types.Stage, env *types.Env) error {
	projectDir := fmt.Sprintf("/opt/%s", repoName)
	localFile := filepath.Join(c.cicdDir, fmt.Sprintf(".env.%s", stage.Name))

	f, err := os.Create(localFile)
	if err != nil {
		return err
	}
	for k, v := range env.Values {
		fmt.Fprintf(f, "%s=%s\n", k, v)
	}
	f.Close()

	auth := sshAuth(stage)
	out, err := c.ssh.Copy(auth, localFile, fmt.Sprintf("%s/.env", projectDir))
	if err != nil {
		return fmt.Errorf("upload env: %w: %s", err, out)
	}
	// secure file
	out, err = c.ssh.Run(auth, fmt.Sprintf(
		"chown deployer:deployer %s/.env && chmod 600 %s/.env",
		projectDir, projectDir,
	))
	if err != nil {
		return fmt.Errorf("secure env: %w: %s", err, out)
	}
	return nil
}

func sshAuth(s types.Stage) ssh.SSHAuth {
	return ssh.SSHAuth{
		User:     "root",
		Host:     s.Host,
		Port:     s.Port,
		KeyPath:  s.RootKeyPath,
		Password: s.RootPass,
	}
}
