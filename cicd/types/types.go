package types

// Stage represents a deployment stage (test, prod, staging, etc.)
type Stage struct {
	Name        string `yaml:"name" json:"name"`
	Host        string `yaml:"host" json:"host"`
	Port        int    `yaml:"port" json:"port"`
	AuthMethod  string `yaml:"auth_method" json:"auth_method"` // key|pass
	RootKeyPath string `yaml:"root_key_path,omitempty" json:"root_key_path,omitempty"`
	RootPass    string `yaml:"root_pass,omitempty" json:"root_pass,omitempty"`
	Domain      string `yaml:"domain,omitempty" json:"domain,omitempty"`
	Branch      string `yaml:"branch" json:"branch"` // develop|main
	EnvFile     string `yaml:"env_file,omitempty" json:"env_file,omitempty"`
	ContainerID string `yaml:"container_id,omitempty" json:"container_id,omitempty"`
}

// SSHKeyPair holds public and private key paths
type SSHKeyPair struct {
	PrivateKey string
	PublicKey  string
	Passphrase string
}

// Env holds environment variables for a stage
type Env struct {
	Stage  string
	Values map[string]string
}

// WorkflowConfig holds parameters for pipeline generation
type WorkflowConfig struct {
	Stages        []Stage
	RepoOwner     string
	RepoName      string
	DeployUser    string
	DeployDirBase string
}

// NginxOptions configures reverse proxy setup
type NginxOptions struct {
	Stage        string
	Host         string
	Domain       string
	ExternalPort int
	AppPort      int
	SSL          bool
}

// Config is the persistent state of the setup
type Config struct {
	Version     string            `yaml:"version" json:"version"`
	RepoOwner   string            `yaml:"repo_owner" json:"repo_owner"`
	RepoName    string            `yaml:"repo_name" json:"repo_name"`
	RepoFull    string            `yaml:"repo_full" json:"repo_full"`
	ProjectRoot string            `yaml:"project_root" json:"project_root"`
	Stages      []Stage           `yaml:"stages" json:"stages"`
	PhaseStatus map[string]bool   `yaml:"phase_status" json:"phase_status"`
	Generated   []string          `yaml:"generated,omitempty" json:"generated,omitempty"`
	Metadata    map[string]string `yaml:"metadata,omitempty" json:"metadata,omitempty"`
}

// Phase identifiers.
const (
	PhaseStageConfig   = "3"
	PhaseProvision     = "4"
	PhaseEnv           = "5"
	PhaseCompose       = "6"
	PhaseNginx         = "65"
	PhaseWorkflow      = "7"
	PhaseGitHub        = "8"
	PhaseCommit        = "9"
	PhaseSmoke         = "10"
	PhaseInitialDeploy = "105"
)
