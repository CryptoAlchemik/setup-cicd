package stage

import (
	"fmt"

	"github.com/CryptoAlchemik/setup-cicd/cicd/types"
)

type Options struct {
	Host       string
	Port       int
	AuthMethod string
	RootKey    string
	RootPass   string
	Branch     string
}

type Manager struct {
	stages []types.Stage
}

func New() *Manager {
	return &Manager{}
}

func (m *Manager) DetectFromProject(stages []types.Stage) error {
	if len(stages) > 0 {
		m.stages = stages
		return nil
	}
	// defaults
	m.stages = []types.Stage{
		{Name: "test", Port: 22, Branch: "develop", AuthMethod: "key"},
		{Name: "prod", Port: 22, Branch: "main", AuthMethod: "key"},
	}
	return nil
}

func (m *Manager) Add(name string, opts Options) error {
	for _, s := range m.stages {
		if s.Name == name {
			return fmt.Errorf("stage %q already exists", name)
		}
	}
	m.stages = append(m.stages, types.Stage{
		Name:        name,
		Host:        opts.Host,
		Port:        opts.Port,
		AuthMethod:  opts.AuthMethod,
		RootKeyPath: opts.RootKey,
		RootPass:    opts.RootPass,
		Branch:      opts.Branch,
	})
	return nil
}

func (m *Manager) Update(name string, opts Options) error {
	for i, s := range m.stages {
		if s.Name == name {
			if opts.Host != "" {
				m.stages[i].Host = opts.Host
			}
			if opts.Port != 0 {
				m.stages[i].Port = opts.Port
			}
			if opts.AuthMethod != "" {
				m.stages[i].AuthMethod = opts.AuthMethod
			}
			if opts.RootKey != "" {
				m.stages[i].RootKeyPath = opts.RootKey
			}
			if opts.RootPass != "" {
				m.stages[i].RootPass = opts.RootPass
			}
			if opts.Branch != "" {
				m.stages[i].Branch = opts.Branch
			}
			return nil
		}
	}
	return fmt.Errorf("stage %q not found", name)
}

func (m *Manager) Remove(name string) error {
	for i, s := range m.stages {
		if s.Name == name {
			m.stages = append(m.stages[:i], m.stages[i+1:]...)
			return nil
		}
	}
	return fmt.Errorf("stage %q not found", name)
}

func (m *Manager) List() []types.Stage {
	out := make([]types.Stage, len(m.stages))
	copy(out, m.stages)
	return out
}

func (m *Manager) Get(name string) *types.Stage {
	for i := range m.stages {
		if m.stages[i].Name == name {
			return &m.stages[i]
		}
	}
	return nil
}
