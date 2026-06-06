package state

import (
	"os"
	"path/filepath"

	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
	"gopkg.in/yaml.v3"
)

const (
	stateDir  = ".cicd"
	stateFile = "state.yaml"
)

type Store struct {
	path string
}

func New(projectRoot string) *Store {
	return &Store{path: filepath.Join(projectRoot, stateDir, stateFile)}
}

func (s *Store) Load() (*types.Config, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return &types.Config{
				Version:     "1",
				PhaseStatus: make(map[string]bool),
				Metadata:    make(map[string]string),
			}, nil
		}
		return nil, err
	}
	var cfg types.Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	if cfg.PhaseStatus == nil {
		cfg.PhaseStatus = make(map[string]bool)
	}
	if cfg.Metadata == nil {
		cfg.Metadata = make(map[string]string)
	}
	return &cfg, nil
}

func (s *Store) Save(cfg *types.Config) error {
	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	data, err := yaml.Marshal(cfg)
	if err != nil {
		return err
	}
	return os.WriteFile(s.path, data, 0600)
}

func (s *Store) Reset() error {
	if err := os.Remove(s.path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func (s *Store) Path() string {
	return s.path
}
