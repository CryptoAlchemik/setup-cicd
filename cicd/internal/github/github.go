package github

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
)

// Runner executes external commands. Tests can replace this.
type Runner interface {
	CombinedOutput(name string, args ...string) ([]byte, error)
	Output(name string, args ...string) ([]byte, error)
	Run(name string, args ...string) error
}

type execRunner struct{}

func (execRunner) CombinedOutput(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).CombinedOutput()
}

func (execRunner) Output(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).Output()
}

func (execRunner) Run(name string, args ...string) error {
	return exec.Command(name, args...).Run()
}

type Client struct {
	repoFull string
	runner   Runner
}

func New(repoFull string) *Client {
	return NewWithRunner(repoFull, execRunner{})
}

func NewWithRunner(repoFull string, runner Runner) *Client {
	return &Client{repoFull: repoFull, runner: runner}
}

func (c *Client) EnsureAuth() error {
	if err := c.runner.Run("gh", "auth", "status"); err != nil {
		cmd := exec.Command("gh", "auth", "login")
		cmd.Stdin = os.Stdin
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		return cmd.Run()
	}
	return nil
}

func (c *Client) SetSecret(name, value string) error {
	out, err := c.runner.CombinedOutput("gh", "secret", "set", name,
		"--repo", c.repoFull,
		"--body", value,
	)
	if err != nil {
		return fmt.Errorf("set secret %s: %w: %s", name, err, string(out))
	}
	return nil
}

func (c *Client) SetupSecrets(stage types.Stage, privKey string) error {
	upper := strings.ToUpper(stage.Name)

	if err := c.SetSecret(fmt.Sprintf("SSH_HOST_%s", upper), stage.Host); err != nil {
		return err
	}
	if err := c.SetSecret(fmt.Sprintf("SSH_PRIVATE_KEY_%s", upper), privKey); err != nil {
		return err
	}
	return nil
}

func (c *Client) CreateEnvironment(name string) error {
	payload := map[string]string{}
	data, _ := json.Marshal(payload)
	cmd := exec.Command("gh", "api",
		fmt.Sprintf("repos/%s/environments/%s", c.repoFull, name),
		"--method", "PUT",
		"--input", "-",
		"--silent",
	)
	cmd.Stdin = strings.NewReader(string(data))
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("create env %s: %w: %s", name, err, string(out))
	}
	return nil
}

func (c *Client) TriggerWorkflow(name string, ref string) (string, error) {
	out, err := c.runner.CombinedOutput("gh", "workflow", "run", name,
		"--repo", c.repoFull,
		"--ref", ref,
	)
	if err != nil {
		return "", fmt.Errorf("trigger workflow: %w: %s", err, string(out))
	}
	return string(out), nil
}

func (c *Client) WatchRun(runID, repo string) error {
	return c.runner.Run("gh", "run", "watch", runID,
		"--repo", repo,
		"--exit-status",
	)
}

func (c *Client) GetLastRunID(workflow string) (string, error) {
	out, err := c.runner.Output("gh", "run", "list",
		"--repo", c.repoFull,
		"--workflow", workflow,
		"--limit", "1",
		"--json", "databaseId",
		"--jq", ".[0].databaseId",
	)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}
