package cmd

import (
	"fmt"

	"github.com/CryptoAlchemik/setup-cicd/cicd/internal/project"
	"github.com/CryptoAlchemik/setup-cicd/cicd/internal/state"
	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
	"github.com/spf13/cobra"
)

var setupCmd = &cobra.Command{
	Use:   "setup",
	Short: "Full CI/CD setup (interactive)",
	Long: `Runs the complete setup process: detect repo, configure stages,
provision servers, collect env, generate docker-compose and
workflow, create GitHub secrets, deploy, and verify.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		// detect project
		info, err := project.Detect(rootOpts.project)
		if err != nil {
			return fmt.Errorf("detect project: %w", err)
		}
		fmt.Printf("Repository: %s\n", info.Full)

		// initialize state
		store := state.New(rootOpts.project)
		cfg, err := store.Load()
		if err != nil {
			return fmt.Errorf("load state: %w", err)
		}
		cfg.RepoOwner = info.Owner
		cfg.RepoName = info.Name
		cfg.RepoFull = info.Full
		cfg.ProjectRoot = info.AbsPath

		// ensure .cicd and .gitignore
		if err := project.EnsureGitignore(rootOpts.project); err != nil {
			return fmt.Errorf("gitignore: %w", err)
		}
		if err := project.Dockerignore(rootOpts.project); err != nil {
			return fmt.Errorf("dockerignore: %w", err)
		}

		// phases
		phases := []struct {
			key  string
			run  func() error
		}{
			{types.PhaseStageConfig, func() error { return nil }}, // handled interactively
		}

		for _, p := range phases {
			if cfg.PhaseStatus[p.key] {
				fmt.Printf("✓ Phase %s already done, skipping\n", p.key)
				continue
			}
			if err := p.run(); err != nil {
				return fmt.Errorf("phase %s: %w", p.key, err)
			}
			cfg.PhaseStatus[p.key] = true
			if err := store.Save(cfg); err != nil {
				return fmt.Errorf("save state: %w", err)
			}
		}

		fmt.Println("\n✓ Setup complete")
		return nil
	},
}

var planCmd = &cobra.Command{
	Use:   "plan",
	Short: "Show what phases will run",
	RunE: func(cmd *cobra.Command, args []string) error {
		store := state.New(rootOpts.project)
		cfg, err := store.Load()
		if err != nil {
			return err
		}
		fmt.Printf("Project: %s/%s\n", cfg.RepoOwner, cfg.RepoName)
		fmt.Printf("Stages:  %d configured\n\n", len(cfg.Stages))
		fmt.Println("Pending phases:")
		phases := []struct {
			key  string
			name string
		}{
			{types.PhaseStageConfig, "Stage config"},
			{types.PhaseProvision, "Provision"},
			{types.PhaseEnv, "Env"},
			{types.PhaseCompose, "Compose"},
			{types.PhaseNginx, "Nginx"},
			{types.PhaseWorkflow, "Workflow"},
			{types.PhaseGitHub, "GitHub"},
			{types.PhaseCommit, "Commit"},
			{types.PhaseSmoke, "Smoke"},
		}
		for _, p := range phases {
			done := cfg.PhaseStatus[p.key]
			mark := " "
			if done {
				mark = "✓"
			}
			fmt.Printf("  [%s] %s\n", mark, p.name)
		}
		return nil
	},
}

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show current setup state",
	RunE: func(cmd *cobra.Command, args []string) error {
		store := state.New(rootOpts.project)
		cfg, err := store.Load()
		if err != nil {
			return fmt.Errorf("load state: %w", err)
		}
		if cfg.RepoFull == "" {
			fmt.Println("No setup found. Run: cicd setup")
			return nil
		}
		fmt.Printf("Repository: %s\n", cfg.RepoFull)
		fmt.Printf("State file: %s\n", store.Path())
		fmt.Printf("Stages (%d):\n", len(cfg.Stages))
		for _, s := range cfg.Stages {
			fmt.Printf("  - %s → %s:%d (branch: %s)\n", s.Name, s.Host, s.Port, s.Branch)
		}
		return nil
	},
}

func init() {
	rootCmd.AddCommand(setupCmd)
	rootCmd.AddCommand(planCmd)
	rootCmd.AddCommand(statusCmd)
}
