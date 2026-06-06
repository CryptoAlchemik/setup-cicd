package ssh

import (
	"fmt"
	"os"
	"os/exec"

	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
)

// Runner executes external commands. Tests can replace this.
type Runner interface {
	CombinedOutput(name string, args ...string) ([]byte, error)
}

type execRunner struct{}

func (execRunner) CombinedOutput(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).CombinedOutput()
}

type SSHAuth struct {
	User       string
	Host       string
	Port       int
	KeyPath    string
	Password   string
	Passphrase string
}

type Client struct {
	baseOpts []string
	runner   Runner
}

func New() *Client {
	return NewWithRunner(execRunner{})
}

func NewWithRunner(r Runner) *Client {
	return &Client{
		baseOpts: []string{
			"-o", "StrictHostKeyChecking=accept-new",
			"-o", "ConnectTimeout=15",
			"-o", "LogLevel=ERROR",
		},
		runner: r,
	}
}

func (c *Client) Run(auth SSHAuth, cmd string) (string, error) {
	args := append([]string{}, c.baseOpts...)
	args = append(args, "-p", fmt.Sprintf("%d", auth.Port))
	if auth.KeyPath != "" {
		args = append(args, "-i", auth.KeyPath)
	}
	args = append(args, fmt.Sprintf("root@%s", auth.Host), cmd)
	return c.exec("ssh", args...)
}

func (c *Client) RunDeployer(auth SSHAuth, cmd string) (string, error) {
	args := append([]string{}, c.baseOpts...)
	args = append(args,
		"-o", "BatchMode=yes",
		"-o", "PasswordAuthentication=no",
		"-p", fmt.Sprintf("%d", auth.Port),
		"-i", auth.KeyPath,
		fmt.Sprintf("deployer@%s", auth.Host),
		cmd,
	)
	return c.exec("ssh", args...)
}

func (c *Client) Copy(auth SSHAuth, src, dst string) (string, error) {
	args := append([]string{}, c.baseOpts...)
	args = append(args, "-P", fmt.Sprintf("%d", auth.Port))
	if auth.KeyPath != "" {
		args = append(args, "-i", auth.KeyPath)
	}
	args = append(args, src, fmt.Sprintf("root@%s:%s", auth.Host, dst))
	return c.exec("scp", args...)
}

func (c *Client) GenerateKeyPair(name, comment string) (*types.SSHKeyPair, error) {
	priv := fmt.Sprintf("%s/.ssh/%s", homedir(), name)
	out, err := c.runner.CombinedOutput("ssh-keygen",
		"-t", "ed25519",
		"-f", priv,
		"-N", "",
		"-C", comment,
		"-q",
	)
	if err != nil {
		return nil, fmt.Errorf("ssh-keygen: %w: %s", err, string(out))
	}
	return &types.SSHKeyPair{
		PrivateKey: priv,
		PublicKey:  priv + ".pub",
	}, nil
}

func (c *Client) exec(bin string, args ...string) (string, error) {
	out, err := c.runner.CombinedOutput(bin, args...)
	if err != nil {
		return string(out), fmt.Errorf("%s: %w: %s", bin, err, string(out))
	}
	return string(out), nil
}

func homedir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "."
	}
	return home
}
