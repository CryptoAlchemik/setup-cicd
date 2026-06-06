package workflow

import (
	"os"
	"path/filepath"
	"strings"
	"text/template"

	ctpl "github.com/CryptoAlchemik/setup-cicd/cicd/internal/templates"
	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
)

const (
	workflowDir  = ".github/workflows"
	workflowFile = "pipeline.yml"
	deployUser   = "deployer"
	deployBase   = "/opt"
)

type Generator struct {
	projectRoot string
}

type stageView struct {
	Name  string
	Upper string
	Branch string
}

type renderData struct {
	DeployUser string
	DeployDir  string
	Stages     []stageView
}

func New(projectRoot string) *Generator {
	return &Generator{projectRoot: projectRoot}
}

func (g *Generator) Generate(cfg *types.Config) (string, error) {
	data := renderData{
		DeployUser: deployUser,
		DeployDir:  deployBase + "/" + cfg.RepoName,
	}
	stagesCount := len(cfg.Stages)
	for _, stage := range cfg.Stages {
		branch := stage.Branch
		if branch == "" {
			if stagesCount == 1 {
				branch = "main"
			} else if len(data.Stages) == 0 {
				branch = "develop"
			} else {
				branch = "main"
			}
		}
			data.Stages = append(data.Stages, stageView{
				Name:   stage.Name,
				Upper:  strings.ToUpper(stage.Name),
				Branch: branch,
			})
	}

	outPath := filepath.Join(g.projectRoot, workflowDir, workflowFile)
	if err := os.MkdirAll(filepath.Dir(outPath), 0755); err != nil {
		return "", err
	}
	tplBytes, err := ctpl.FS.ReadFile("workflow.tmpl")
	if err != nil {
		return "", err
	}
	tpl, err := template.New("workflow").Parse(string(tplBytes))
	if err != nil {
		return "", err
	}
	f, err := os.Create(outPath)
	if err != nil {
		return "", err
	}
	defer f.Close()
	if err := tpl.Execute(f, data); err != nil {
		return "", err
	}
	return outPath, nil
}
