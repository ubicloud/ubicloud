// HCL2 spec for the Ubicloud builder config.
// This is a minimal hand-written spec to satisfy the packer Builder interface.

package ubicloud

import (
	"github.com/hashicorp/hcl/v2/hcldec"
	"github.com/zclconf/go-cty/cty"
)

// FlatConfig is a flat version of Config for HCL2 support.
type FlatConfig struct {
	APIToken         *string `mapstructure:"api_token" cty:"api_token" hcl:"api_token"`
	APIURL           *string `mapstructure:"api_url" cty:"api_url" hcl:"api_url"`
	ProjectID        *string `mapstructure:"project_id" cty:"project_id" hcl:"project_id"`
	Location         *string `mapstructure:"location" cty:"location" hcl:"location"`
	BootImage        *string `mapstructure:"boot_image" cty:"boot_image" hcl:"boot_image"`
	VMSize           *string `mapstructure:"vm_size" cty:"vm_size" hcl:"vm_size"`
	VMArch           *string `mapstructure:"vm_arch" cty:"vm_arch" hcl:"vm_arch"`
	StorageSize      *int    `mapstructure:"storage_size" cty:"storage_size" hcl:"storage_size"`
	ImageName        *string `mapstructure:"image_name" cty:"image_name" hcl:"image_name"`
	ImageDescription *string `mapstructure:"image_description" cty:"image_description" hcl:"image_description"`

	// SSH communicator fields
	SSHUsername                *string `mapstructure:"ssh_username" cty:"ssh_username" hcl:"ssh_username"`
	SSHPassword                *string `mapstructure:"ssh_password" cty:"ssh_password" hcl:"ssh_password"`
	SSHPrivateKeyFile          *string `mapstructure:"ssh_private_key_file" cty:"ssh_private_key_file" hcl:"ssh_private_key_file"`
	SSHPort                    *int    `mapstructure:"ssh_port" cty:"ssh_port" hcl:"ssh_port"`
	SSHTimeout                 *string `mapstructure:"ssh_timeout" cty:"ssh_timeout" hcl:"ssh_timeout"`
	SSHHandshakeAttempts       *int    `mapstructure:"ssh_handshake_attempts" cty:"ssh_handshake_attempts" hcl:"ssh_handshake_attempts"`
	SSHAgentAuth               *bool   `mapstructure:"ssh_agent_auth" cty:"ssh_agent_auth" hcl:"ssh_agent_auth"`
	SSHDisableAgentForwarding  *bool   `mapstructure:"ssh_disable_agent_forwarding" cty:"ssh_disable_agent_forwarding" hcl:"ssh_disable_agent_forwarding"`
	SSHBastionHost             *string `mapstructure:"ssh_bastion_host" cty:"ssh_bastion_host" hcl:"ssh_bastion_host"`
	SSHBastionPort             *int    `mapstructure:"ssh_bastion_port" cty:"ssh_bastion_port" hcl:"ssh_bastion_port"`
	SSHBastionUsername         *string `mapstructure:"ssh_bastion_username" cty:"ssh_bastion_username" hcl:"ssh_bastion_username"`
	SSHBastionPassword         *string `mapstructure:"ssh_bastion_password" cty:"ssh_bastion_password" hcl:"ssh_bastion_password"`
	SSHBastionPrivateKeyFile   *string `mapstructure:"ssh_bastion_private_key_file" cty:"ssh_bastion_private_key_file" hcl:"ssh_bastion_private_key_file"`
	SSHBastionAgentAuth        *bool   `mapstructure:"ssh_bastion_agent_auth" cty:"ssh_bastion_agent_auth" hcl:"ssh_bastion_agent_auth"`
	SSHProxyHost               *string `mapstructure:"ssh_proxy_host" cty:"ssh_proxy_host" hcl:"ssh_proxy_host"`
	SSHProxyPort               *int    `mapstructure:"ssh_proxy_port" cty:"ssh_proxy_port" hcl:"ssh_proxy_port"`
	SSHProxyUsername           *string `mapstructure:"ssh_proxy_username" cty:"ssh_proxy_username" hcl:"ssh_proxy_username"`
	SSHProxyPassword           *string `mapstructure:"ssh_proxy_password" cty:"ssh_proxy_password" hcl:"ssh_proxy_password"`
}

// FlatMapstructure returns the flat mapstructure for HCL2 support.
func (*Config) FlatMapstructure() interface{ HCL2Spec() map[string]hcldec.Spec } {
	return new(FlatConfig)
}

// HCL2Spec returns the hcldec spec for all supported source block attributes.
func (*FlatConfig) HCL2Spec() map[string]hcldec.Spec {
	return map[string]hcldec.Spec{
		// Builder settings
		"api_token":         &hcldec.AttrSpec{Name: "api_token", Type: cty.String, Required: true},
		"api_url":           &hcldec.AttrSpec{Name: "api_url", Type: cty.String, Required: false},
		"project_id":        &hcldec.AttrSpec{Name: "project_id", Type: cty.String, Required: true},
		"location":          &hcldec.AttrSpec{Name: "location", Type: cty.String, Required: true},
		"boot_image":        &hcldec.AttrSpec{Name: "boot_image", Type: cty.String, Required: false},
		"vm_size":           &hcldec.AttrSpec{Name: "vm_size", Type: cty.String, Required: false},
		"vm_arch":           &hcldec.AttrSpec{Name: "vm_arch", Type: cty.String, Required: false},
		"storage_size":      &hcldec.AttrSpec{Name: "storage_size", Type: cty.Number, Required: false},
		"image_name":        &hcldec.AttrSpec{Name: "image_name", Type: cty.String, Required: true},
		"image_description": &hcldec.AttrSpec{Name: "image_description", Type: cty.String, Required: false},
		// SSH communicator settings
		"ssh_username":                  &hcldec.AttrSpec{Name: "ssh_username", Type: cty.String, Required: false},
		"ssh_password":                  &hcldec.AttrSpec{Name: "ssh_password", Type: cty.String, Required: false},
		"ssh_private_key_file":          &hcldec.AttrSpec{Name: "ssh_private_key_file", Type: cty.String, Required: false},
		"ssh_port":                      &hcldec.AttrSpec{Name: "ssh_port", Type: cty.Number, Required: false},
		"ssh_timeout":                   &hcldec.AttrSpec{Name: "ssh_timeout", Type: cty.String, Required: false},
		"ssh_handshake_attempts":        &hcldec.AttrSpec{Name: "ssh_handshake_attempts", Type: cty.Number, Required: false},
		"ssh_agent_auth":                &hcldec.AttrSpec{Name: "ssh_agent_auth", Type: cty.Bool, Required: false},
		"ssh_disable_agent_forwarding":  &hcldec.AttrSpec{Name: "ssh_disable_agent_forwarding", Type: cty.Bool, Required: false},
		"ssh_bastion_host":              &hcldec.AttrSpec{Name: "ssh_bastion_host", Type: cty.String, Required: false},
		"ssh_bastion_port":              &hcldec.AttrSpec{Name: "ssh_bastion_port", Type: cty.Number, Required: false},
		"ssh_bastion_username":          &hcldec.AttrSpec{Name: "ssh_bastion_username", Type: cty.String, Required: false},
		"ssh_bastion_password":          &hcldec.AttrSpec{Name: "ssh_bastion_password", Type: cty.String, Required: false},
		"ssh_bastion_private_key_file":  &hcldec.AttrSpec{Name: "ssh_bastion_private_key_file", Type: cty.String, Required: false},
		"ssh_bastion_agent_auth":        &hcldec.AttrSpec{Name: "ssh_bastion_agent_auth", Type: cty.Bool, Required: false},
		"ssh_proxy_host":                &hcldec.AttrSpec{Name: "ssh_proxy_host", Type: cty.String, Required: false},
		"ssh_proxy_port":                &hcldec.AttrSpec{Name: "ssh_proxy_port", Type: cty.Number, Required: false},
		"ssh_proxy_username":            &hcldec.AttrSpec{Name: "ssh_proxy_username", Type: cty.String, Required: false},
		"ssh_proxy_password":            &hcldec.AttrSpec{Name: "ssh_proxy_password", Type: cty.String, Required: false},
	}
}

// ConfigSpec returns the hcldec.ObjectSpec for HCL2 template support.
func (b *Builder) ConfigSpec() hcldec.ObjectSpec {
	return b.config.FlatMapstructure().HCL2Spec()
}
