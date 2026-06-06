package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	CICDDir      = ".cicd"
	DefaultPort  = 22
	DeployUser   = "deployer"
	DeployBase   = "/opt"
)

// ResolvePaths creates the .cicd directory and writes .gitignore entry
func Init(projectRoot string) error {
	dir := filepath.Join(projectRoot, CICDDir)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	return ensureGitignore(projectRoot)
}

func ensureGitignore(projectRoot string) error {
	path := filepath.Join(projectRoot, ".gitignore")
	entry := CICDDir + "/"

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return os.WriteFile(path, []byte(entry+"\n"), 0644)
		}
		return err
	}
	if strings.Contains(string(data), entry) {
		return nil
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString("\n" + entry + "\n")
	return err
}

func LocalEnvPath(projectRoot, stage string) string {
	return filepath.Join(projectRoot, CICDDir, fmt.Sprintf(".env.%s", stage))
}

func SSHKeyPath(projectRoot, repoName, stage string) string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".ssh", fmt.Sprintf("cicd_%s_%s", repoName, stage))
}

func DeployDir(repoName string) string {
	return filepath.Join(DeployBase, repoName)
}
