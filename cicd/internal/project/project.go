package project

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type Info struct {
	Owner   string
	Name    string
	Full    string
	AbsPath string
}

// Detect reads the project repo info from git remote
func Detect(projectRoot string) (*Info, error) {
	dotgit := filepath.Join(projectRoot, ".git")
	if _, err := os.Stat(dotgit); os.IsNotExist(err) {
		return nil, fmt.Errorf("not a git repository: %s", projectRoot)
	}

	remote, err := getRemoteURL(projectRoot)
	if err != nil {
		return nil, err
	}

	re := regexp.MustCompile(`github\.com[:/]([^/]+)/([^/.]+)(\.git)?$`)
	matches := re.FindStringSubmatch(remote)
	if len(matches) < 3 {
		return nil, fmt.Errorf("remote doesn't look like a GitHub URL: %s", remote)
	}

	abs, _ := filepath.Abs(projectRoot)
	return &Info{
		Owner:   matches[1],
		Name:    matches[2],
		Full:    fmt.Sprintf("%s/%s", matches[1], matches[2]),
		AbsPath: abs,
	}, nil
}

func getRemoteURL(projectRoot string) (string, error) {
	content, err := os.ReadFile(filepath.Join(projectRoot, ".git", "config"))
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(content), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "url = ") {
			return strings.TrimPrefix(line, "url = "), nil
		}
	}
	return "", fmt.Errorf("no remote origin found")
}

// HasFile checks for existence of common project files
func HasFile(root, name string) bool {
	_, err := os.Stat(filepath.Join(root, name))
	return err == nil
}

// EnsureGitignore adds .cicd/ to .gitignore if not present
func EnsureGitignore(root string) error {
	path := filepath.Join(root, ".gitignore")
	entry := ".cicd/"

	data, _ := os.ReadFile(path)
	if strings.Contains(string(data), entry) {
		return nil
	}

	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString("\n" + entry + "\n")
	return err
}

// Dockerignore creates default .dockerignore if not exists
func Dockerignore(root string) error {
	path := filepath.Join(root, ".dockerignore")
	if HasFile(root, ".dockerignore") {
		return nil
	}
	content := strings.TrimPrefix(`
.venv/
__pycache__/
*.pyc
.env
.env.*
!.env.example
.git/
.github/
.cicd/
*.db
logs/
*.log
`, "\n")
	return os.WriteFile(path, []byte(content), 0644)
}
