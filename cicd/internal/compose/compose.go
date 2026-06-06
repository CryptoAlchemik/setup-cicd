package compose

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/CryptoAlchemik/setup-cicd/cicd/internal/ssh"
	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
)

type Generator struct {
	ssh         *ssh.Client
	projectRoot string
}

func New(s *ssh.Client, projectRoot string) *Generator {
	return &Generator{
		ssh:         s,
		projectRoot: projectRoot,
	}
}

func (g *Generator) Generate(stage types.Stage, config *types.Config) (string, error) {
	image := fmt.Sprintf("ghcr.io/%s/%s:%s-latest",
		strings.ToLower(config.RepoOwner),
		strings.ToLower(config.RepoName),
		stage.Name,
	)

	localFile := filepath.Join(g.projectRoot, "docker-compose.yml")
	outFile := filepath.Join(g.projectRoot, fmt.Sprintf("docker-compose.%s.yml", stage.Name))

	if _, err := os.Stat(localFile); err == nil {
		return g.transform(localFile, outFile, image)
	}
	return g.minimal(outFile, image)
}

func (g *Generator) transform(src, dst, image string) (string, error) {
	data, err := os.ReadFile(src)
	if err != nil {
		return "", err
	}
	content := string(data)

	// replace build: . with image:
	content = strings.ReplaceAll(content, "build: .", fmt.Sprintf("image: %s", image))

	// remove host volume mounts (./ or ./
	lines := strings.Split(content, "\n")
	var out []string
	skipVol := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "- ./") || strings.HasPrefix(trimmed, "- .:") {
			continue
		}
		if strings.HasPrefix(trimmed, "volumes:") {
			skipVol = true
			continue
		}
		if skipVol {
			if strings.HasPrefix(trimmed, "- ") {
				continue
			}
			skipVol = false
		}
		out = append(out, line)
	}
	content = strings.Join(out, "\n")

	if err := os.WriteFile(dst, []byte(content), 0644); err != nil {
		return "", err
	}
	return dst, nil
}

func (g *Generator) minimal(dst, image string) (string, error) {
	content := fmt.Sprintf(`version: "3.9"

services:
  app:
    image: %s
    restart: unless-stopped
    env_file: .env
    ports:
      - "8000:8000"
`, image)
	if err := os.WriteFile(dst, []byte(content), 0644); err != nil {
		return "", err
	}
	return dst, nil
}

func (g *Generator) Upload(repoName string, stage types.Stage) error {
	projectDir := fmt.Sprintf("/opt/%s", repoName)
	localFile := filepath.Join(g.projectRoot, fmt.Sprintf("docker-compose.%s.yml", stage.Name))

	auth := ssh.SSHAuth{
		Host:     stage.Host,
		Port:     stage.Port,
		KeyPath:  stage.RootKeyPath,
		Password: stage.RootPass,
	}
	out, err := g.ssh.Copy(auth, localFile, fmt.Sprintf("%s/", projectDir))
	if err != nil {
		return fmt.Errorf("upload compose: %w: %s", err, out)
	}
	out, err = g.ssh.Run(auth, fmt.Sprintf(
		"chown deployer:deployer %s/docker-compose.%s.yml",
		projectDir, stage.Name,
	))
	if err != nil {
		return fmt.Errorf("chown compose: %w: %s", err, out)
	}
	return nil
}
