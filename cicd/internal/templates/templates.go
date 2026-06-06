package templates

import "embed"

// FS stores embedded template assets.
//
//go:embed workflow.tmpl nginx.tmpl
var FS embed.FS
