package ubicloud

import (
	"context"
	"fmt"

	"github.com/hashicorp/packer-plugin-sdk/common"
	"github.com/hashicorp/packer-plugin-sdk/communicator"
	"github.com/hashicorp/packer-plugin-sdk/multistep"
	"github.com/hashicorp/packer-plugin-sdk/multistep/commonsteps"
	packersdk "github.com/hashicorp/packer-plugin-sdk/packer"
)

const builderID = "ubicloud.builder"

// Builder is the Ubicloud Packer builder.
type Builder struct {
	config Config
	runner multistep.Runner
}

func (b *Builder) Prepare(raws ...interface{}) (generatedVars []string, warnings []string, err error) {
	warns, err := b.config.Prepare(raws...)
	return nil, warns, err
}

func (b *Builder) Run(ctx context.Context, ui packersdk.Ui, hook packersdk.Hook) (packersdk.Artifact, error) {
	client := NewClient(b.config.APIURL, b.config.APIToken, b.config.ProjectID, b.config.Location)

	// State bag for passing data between steps
	state := new(multistep.BasicStateBag)
	state.Put("config", &b.config)
	state.Put("ui", ui)
	state.Put("hook", hook)

	steps := []multistep.Step{
		&StepCreateVM{config: &b.config, client: client},
		&StepWaitSSH{config: &b.config, client: client},
		&communicator.StepConnect{
			Config: &b.config.Comm,
			Host:   communicator.CommHost(b.config.Comm.Host(), "ssh_host"),
			SSHConfig: b.config.Comm.SSHConfigFunc(),
		},
		&commonsteps.StepProvision{},
		&commonsteps.StepCleanupTempKeys{
			Comm: &b.config.Comm,
		},
		&StepStopVM{client: client},
		&StepCreateImage{config: &b.config, client: client},
		&StepDestroyVM{client: client},
	}

	b.runner = commonsteps.NewRunnerWithPauseFn(steps, b.config.PackerConfig, ui, state)
	b.runner.Run(ctx, state)

	if rawErr, ok := state.GetOk("error"); ok {
		return nil, rawErr.(error)
	}

	imageID, ok := state.GetOk("image_id")
	if !ok {
		return nil, fmt.Errorf("build was successful but image_id not found in state")
	}

	imageName, _ := state.GetOk("image_name")

	artifact := &Artifact{
		ImageID:   imageID.(string),
		ImageName: imageName.(string),
		Location:  b.config.Location,
		ProjectID: b.config.ProjectID,
	}

	return artifact, nil
}

// Ensure Builder implements packersdk.Builder
var _ packersdk.Builder = (*Builder)(nil)

// Ensure common.PackerConfig is embedded (to satisfy certain interfaces)
var _ common.PackerConfig = common.PackerConfig{}
