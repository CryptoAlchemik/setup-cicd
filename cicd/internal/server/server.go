package server

import (
	"fmt"
	"os"

	"github.com/CryptoAlchemik/setup-cicd/cicd/internal/ssh"
	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
)

const (
	deployUser     = "deployer"
	deployDirBase  = "/opt"
)

type Provisioner struct {
	ssh *ssh.Client
}

func New(s *ssh.Client) *Provisioner {
	return &Provisioner{ssh: s}
}

func (p *Provisioner) Provision(repoName string, stage types.Stage, key *types.SSHKeyPair) error {
	pubkey, err := readFile(key.PublicKey)
	if err != nil {
		return fmt.Errorf("read public key: %w", err)
	}

	projectDir := fmt.Sprintf("%s/%s", deployDirBase, repoName)
	auth := sshAuth(stage)

	script := fmt.Sprintf(`set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Docker
if ! command -v docker &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker --now
fi

# Docker Compose
if ! docker compose version &>/dev/null; then
  apt-get install -y -qq docker-compose-plugin
fi

# Deployer user
if ! id %[1]s &>/dev/null; then
  useradd -m -s /bin/bash %[1]s
fi
usermod -aG docker %[1]s

# SSH key
mkdir -p /home/%[1]s/.ssh
grep -v "cicd-%[2]s" /home/%[1]s/.ssh/authorized_keys > /tmp/_ak 2>/dev/null || true
echo '%[3]s' >> /tmp/_ak
mv /tmp/_ak /home/%[1]s/.ssh/authorized_keys
chmod 700 /home/%[1]s/.ssh
chmod 600 /home/%[1]s/.ssh/authorized_keys
chown -R %[1]s:%[1]s /home/%[1]s/.ssh

# Project dir
mkdir -p %[4]s
chown %[1]s:%[1]s %[4]s
`, deployUser, stage.Name, pubkey, projectDir)

	out, err := p.ssh.Run(auth, script)
	if err != nil {
		return fmt.Errorf("provision %s: %w: %s", stage.Name, err, out)
	}
	return nil
}

func (p *Provisioner) Verify(stage types.Stage) error {
	auth := sshAuth(stage)
	auth.User = deployUser
	out, err := p.ssh.RunDeployer(auth, "docker ps -q | wc -l")
	if err != nil {
		return fmt.Errorf("verify deployer ssh: %w: %s", err, out)
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

func readFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(data), nil
}
