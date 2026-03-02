package ubicloud

import (
	"errors"
	"fmt"

	"github.com/hashicorp/packer-plugin-sdk/common"
	"github.com/hashicorp/packer-plugin-sdk/communicator"
	packersdk "github.com/hashicorp/packer-plugin-sdk/packer"
	"github.com/hashicorp/packer-plugin-sdk/template/config"
	"github.com/hashicorp/packer-plugin-sdk/template/interpolate"
)

// Config holds the configuration for the Ubicloud builder.
type Config struct {
	common.PackerConfig `mapstructure:",squash"`

	// Authentication
	APIToken string `mapstructure:"api_token" required:"true"`
	APIURL   string `mapstructure:"api_url"`

	// Target project and location
	ProjectID string `mapstructure:"project_id" required:"true"`
	Location  string `mapstructure:"location" required:"true"`

	// Builder VM settings
	BootImage   string `mapstructure:"boot_image"`
	VMSize      string `mapstructure:"vm_size"`
	VMArch      string `mapstructure:"vm_arch"`
	StorageSize int    `mapstructure:"storage_size"`

	// Output image settings
	ImageName        string `mapstructure:"image_name" required:"true"`
	ImageDescription string `mapstructure:"image_description"`

	// SSH communicator config
	Comm communicator.Config `mapstructure:",squash"`

	ctx interpolate.Context
}

func (c *Config) Prepare(raws ...interface{}) ([]string, error) {
	err := config.Decode(c, &config.DecodeOpts{
		PluginType:         "packer.builder.ubicloud",
		Interpolate:        true,
		InterpolateContext: &c.ctx,
		InterpolateFilter: &interpolate.RenderFilter{
			Exclude: []string{},
		},
	}, raws...)
	if err != nil {
		return nil, err
	}

	var errs *packersdk.MultiError

	// Set defaults
	if c.APIURL == "" {
		c.APIURL = "https://api.ubicloud.com"
	}
	if c.BootImage == "" {
		c.BootImage = "ubuntu-noble"
	}
	if c.VMSize == "" {
		c.VMSize = "standard-2"
	}
	if c.Comm.Type == "" {
		c.Comm.Type = "ssh"
	}
	if c.Comm.SSH.SSHUsername == "" {
		c.Comm.SSH.SSHUsername = "ubi"
	}

	// Validate required fields
	if c.APIToken == "" {
		errs = packersdk.MultiErrorAppend(errs, errors.New("api_token is required"))
	}
	if c.ProjectID == "" {
		errs = packersdk.MultiErrorAppend(errs, errors.New("project_id is required"))
	}
	if c.Location == "" {
		errs = packersdk.MultiErrorAppend(errs, errors.New("location is required"))
	}
	if c.ImageName == "" {
		errs = packersdk.MultiErrorAppend(errs, errors.New("image_name is required"))
	}

	// Validate communicator
	if es := c.Comm.Prepare(&c.ctx); len(es) > 0 {
		errs = packersdk.MultiErrorAppend(errs, es...)
	}

	if errs != nil && len(errs.Errors) > 0 {
		return nil, errs
	}

	return nil, nil
}

// TempVMName returns the name for the temporary builder VM.
func (c *Config) TempVMName() string {
	return fmt.Sprintf("packer-%s", c.ImageName)
}
