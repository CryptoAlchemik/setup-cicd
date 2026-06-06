package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var rootOpts struct {
	project string
	yes     bool
	dryRun  bool
	state   string
}

var rootCmd = &cobra.Command{
	Use:   "cicd",
	Short: "CI/CD bootstrap — GitHub Actions + Docker + GHCR + SSH deploy",
	Long: `Universal CI/CD setup tool. Detects your project, provisions servers,
generates GitHub Actions workflow, creates secrets, and deploys.

  cicd setup          Full setup (interactive orchestrator)
  cicd plan           Show what phases will run
  cicd provision      Provision servers for all stages
  cicd env            Collect and upload .env files
  cicd compose        Generate and upload docker-compose
  cicd nginx          Configure nginx reverse proxy
  cicd workflow       Generate GitHub Actions pipeline
  cicd github         Configure GitHub secrets & environments
  cicd deploy         Trigger deploy via GitHub Actions
  cicd verify         Smoke test deployer SSH
  cicd status         Show current setup state
  cicd stage add      Add a deployment stage
  cicd stage update   Update a stage
  cicd stage remove   Remove a stage
`,
	PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
		if rootOpts.project == "" {
			p, err := os.Getwd()
			if err != nil {
				return err
			}
			rootOpts.project = p
		}
		return nil
	},
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func init() {
	rootCmd.PersistentFlags().StringVarP(&rootOpts.project, "project", "p", "", "Project root directory (default: cwd)")
	rootCmd.PersistentFlags().BoolVarP(&rootOpts.yes, "yes", "y", false, "Skip confirmations")
	rootCmd.PersistentFlags().BoolVar(&rootOpts.dryRun, "dry-run", false, "Show what would be done")
	rootCmd.PersistentFlags().StringVar(&rootOpts.state, "state", "", "Path to state file (default: .cicd/state.yaml)")
}
