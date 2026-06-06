package cmd

import (
	"fmt"

	"github.com/CryptoAlchemik/setup-cicd/cicd/internal/stage"
	"github.com/CryptoAlchemik/setup-cicd/cicd/internal/state"
	"github.com/spf13/cobra"
)

var stageOpts struct {
	name   string
	host   string
	port   int
	auth   string
	key    string
	pass   string
	branch string
}

var stageCmd = &cobra.Command{
	Use:   "stage",
	Short: "Manage deployment stages",
}

var stageAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Add a deployment stage",
	RunE: func(cmd *cobra.Command, args []string) error {
		if stageOpts.name == "" {
			return fmt.Errorf("--name is required")
		}

		store := state.New(rootOpts.project)
		cfg, err := store.Load()
		if err != nil {
			return err
		}

		mgr := stage.New()
		mgr.DetectFromProject(cfg.Stages)
		if err := mgr.Add(stageOpts.name, stage.Options{
			Host:       stageOpts.host,
			Port:       stageOpts.port,
			AuthMethod: stageOpts.auth,
			RootKey:    stageOpts.key,
			RootPass:   stageOpts.pass,
			Branch:     stageOpts.branch,
		}); err != nil {
			return err
		}

		cfg.Stages = mgr.List()
		if err := store.Save(cfg); err != nil {
			return err
		}
		fmt.Printf("Stage %q added\n", stageOpts.name)
		return nil
	},
}

var stageUpdateCmd = &cobra.Command{
	Use:   "update",
	Short: "Update a deployment stage",
	RunE: func(cmd *cobra.Command, args []string) error {
		if stageOpts.name == "" {
			return fmt.Errorf("--name is required")
		}

		store := state.New(rootOpts.project)
		cfg, err := store.Load()
		if err != nil {
			return err
		}

		mgr := stage.New()
		mgr.DetectFromProject(cfg.Stages)
		if err := mgr.Update(stageOpts.name, stage.Options{
			Host:       stageOpts.host,
			Port:       stageOpts.port,
			AuthMethod: stageOpts.auth,
		}); err != nil {
			return err
		}

		cfg.Stages = mgr.List()
		if err := store.Save(cfg); err != nil {
			return err
		}
		fmt.Printf("Stage %q updated\n", stageOpts.name)
		return nil
	},
}

var stageRemoveCmd = &cobra.Command{
	Use:   "remove",
	Short: "Remove a deployment stage",
	RunE: func(cmd *cobra.Command, args []string) error {
		if stageOpts.name == "" {
			return fmt.Errorf("--name is required")
		}

		store := state.New(rootOpts.project)
		cfg, err := store.Load()
		if err != nil {
			return err
		}

		mgr := stage.New()
		mgr.DetectFromProject(cfg.Stages)
		if err := mgr.Remove(stageOpts.name); err != nil {
			return err
		}

		cfg.Stages = mgr.List()
		if err := store.Save(cfg); err != nil {
			return err
		}
		fmt.Printf("Stage %q removed\n", stageOpts.name)
		return nil
	},
}

func init() {
	stageCmd.AddCommand(stageAddCmd)
	stageCmd.AddCommand(stageUpdateCmd)
	stageCmd.AddCommand(stageRemoveCmd)

	stageAddCmd.Flags().StringVarP(&stageOpts.name, "name", "n", "", "Stage name (test, prod, etc)")
	stageAddCmd.Flags().StringVar(&stageOpts.host, "host", "", "Server hostname/IP")
	stageAddCmd.Flags().IntVar(&stageOpts.port, "port", 22, "SSH port")
	stageAddCmd.Flags().StringVar(&stageOpts.auth, "auth", "key", "Auth method: key|pass")
	stageAddCmd.Flags().StringVar(&stageOpts.key, "key", "", "Root SSH key path")
	stageAddCmd.Flags().StringVar(&stageOpts.pass, "pass", "", "Root password")
	stageAddCmd.Flags().StringVar(&stageOpts.branch, "branch", "", "Git branch for this stage (develop|main)")

	stageUpdateCmd.Flags().StringVarP(&stageOpts.name, "name", "n", "", "Stage name")
	stageUpdateCmd.Flags().StringVar(&stageOpts.host, "host", "", "Server hostname/IP")
	stageUpdateCmd.Flags().IntVar(&stageOpts.port, "port", 0, "SSH port")
	stageUpdateCmd.Flags().StringVar(&stageOpts.auth, "auth", "", "Auth method: key|pass")

	stageRemoveCmd.Flags().StringVarP(&stageOpts.name, "name", "n", "", "Stage name")

}
