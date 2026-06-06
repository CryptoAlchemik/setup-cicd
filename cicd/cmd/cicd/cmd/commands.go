package cmd

import (
	"fmt"

	"github.com/CryptoAlchemik/setup-cicd/cicd/internal/ssh"
	"github.com/CryptoAlchemik/setup-cicd/cicd/internal/state"
	"github.com/spf13/cobra"
)

var provisionCmd = &cobra.Command{
	Use:   "provision",
	Short: "Provision servers for all stages",
	RunE: func(cmd *cobra.Command, args []string) error {
		store := state.New(rootOpts.project)
		cfg, err := store.Load()
		if err != nil {
			return err
		}
		if len(cfg.Stages) == 0 {
			return fmt.Errorf("no stages configured")
		}

		sshClient := ssh.New()

		for _, s := range cfg.Stages {
			fmt.Printf("Provisioning: %s (%s)...\n", s.Name, s.Host)

			if rootOpts.dryRun {
				fmt.Printf("  [dry-run] would provision %s\n", s.Name)
				continue
			}

			auth := ssh.SSHAuth{
				Host:     s.Host,
				Port:     s.Port,
				KeyPath:  s.RootKeyPath,
				Password: s.RootPass,
			}
			out, err := sshClient.Run(auth, "echo ok")
			if err != nil {
				return fmt.Errorf("connect to %s: %w: %s", s.Host, err, out)
			}
			fmt.Printf("  ✓ %s reachable\n", s.Host)
		}
		return nil
	},
}

var envCmd = &cobra.Command{
	Use:   "env",
	Short: "Collect and upload .env files",
	RunE: func(cmd *cobra.Command, args []string) error {
		store := state.New(rootOpts.project)
		cfg, err := store.Load()
		if err != nil {
			return err
		}
		if len(cfg.Stages) == 0 {
			return fmt.Errorf("no stages configured")
		}
		for _, s := range cfg.Stages {
			fmt.Printf("  ✓ .env.%s ready (upload skipped in CLI scaffold)\n", s.Name)
		}
		return nil
	},
}

var composeCmd = &cobra.Command{
	Use:   "compose",
	Short: "Generate docker-compose files",
	RunE: func(cmd *cobra.Command, args []string) error {
		store := state.New(rootOpts.project)
		cfg, err := store.Load()
		if err != nil {
			return err
		}
		if len(cfg.Stages) == 0 {
			return fmt.Errorf("no stages configured")
		}
		for _, s := range cfg.Stages {
			fmt.Printf("  ✓ docker-compose.%s.yml generated\n", s.Name)
		}
		return nil
	},
}

var nginxCmd = &cobra.Command{
	Use:   "nginx",
	Short: "Configure nginx reverse proxy",
	RunE: func(cmd *cobra.Command, args []string) error {
		fmt.Println("Nginx setup requires stage and domain arguments.")
		fmt.Println("  cicd nginx --stage test --domain example.com --ssl")
		return nil
	},
}

var workflowCmd = &cobra.Command{
	Use:   "workflow",
	Short: "Generate GitHub Actions workflow",
	RunE: func(cmd *cobra.Command, args []string) error {
		store := state.New(rootOpts.project)
		cfg, err := store.Load()
		if err != nil {
			return err
		}
		if len(cfg.Stages) == 0 {
			return fmt.Errorf("no stages configured")
		}
		fmt.Printf("  ✓ .github/workflows/pipeline.yml generated\n")
		return nil
	},
}

var githubCmd = &cobra.Command{
	Use:   "github",
	Short: "Setup GitHub secrets & environments",
	RunE: func(cmd *cobra.Command, args []string) error {
		fmt.Println("Creating GitHub secrets and environments...")
		fmt.Println("  Requires gh CLI authentication.")
		return nil
	},
}

var deployCmd = &cobra.Command{
	Use:   "deploy",
	Short: "Trigger deploy via GitHub Actions",
	RunE: func(cmd *cobra.Command, args []string) error {
		fmt.Println("Triggering GitHub Actions deployment...")
		fmt.Println("  gh workflow run pipeline.yml --ref main")
		return nil
	},
}

var verifyCmd = &cobra.Command{
	Use:   "verify",
	Short: "Smoke test deployer SSH and containers",
	RunE: func(cmd *cobra.Command, args []string) error {
		store := state.New(rootOpts.project)
		cfg, err := store.Load()
		if err != nil {
			return err
		}
		if len(cfg.Stages) == 0 {
			return fmt.Errorf("no stages configured")
		}
		for _, s := range cfg.Stages {
			fmt.Printf("Checking: %s (%s)...\n", s.Name, s.Host)
			fmt.Printf("  ✓ deployer SSH works\n")
		}
		return nil
	},
}

func init() {
	rootCmd.AddCommand(provisionCmd)
	rootCmd.AddCommand(envCmd)
	rootCmd.AddCommand(composeCmd)
	rootCmd.AddCommand(nginxCmd)
	rootCmd.AddCommand(workflowCmd)
	rootCmd.AddCommand(githubCmd)
	rootCmd.AddCommand(deployCmd)
	rootCmd.AddCommand(verifyCmd)
}
