package ubicloud

import (
	"context"
	"fmt"
	"time"

	"github.com/hashicorp/packer-plugin-sdk/multistep"
	packersdk "github.com/hashicorp/packer-plugin-sdk/packer"
)

// StepCreateImage creates the machine image from the stopped VM.
type StepCreateImage struct {
	config *Config
	client *Client
}

func (s *StepCreateImage) Run(ctx context.Context, state multistep.StateBag) multistep.StepAction {
	ui := state.Get("ui").(packersdk.Ui)
	vmName := state.Get("vm_name").(string)
	vmID := state.Get("vm_id").(string)

	ui.Say(fmt.Sprintf("Creating machine image '%s' from VM '%s'...", s.config.ImageName, vmName))

	req := CreateMachineImageRequest{
		VMID:        vmID,
		Description: s.config.ImageDescription,
	}

	mi, err := s.client.CreateMachineImage(s.config.ImageName, req)
	if err != nil {
		state.Put("error", fmt.Errorf("creating machine image: %w", err))
		return multistep.ActionHalt
	}

	ui.Say(fmt.Sprintf("Machine image '%s' creation started (ID: %s)", mi.Name, mi.ID))
	state.Put("image_id", mi.ID)
	state.Put("image_name", mi.Name)

	ui.Say("Waiting for machine image to become available...")
	timeout := 30 * time.Minute
	start := time.Now()

	for {
		if time.Since(start) > timeout {
			state.Put("error", fmt.Errorf("timeout waiting for machine image to become available"))
			return multistep.ActionHalt
		}

		select {
		case <-ctx.Done():
			state.Put("error", ctx.Err())
			return multistep.ActionHalt
		case <-time.After(15 * time.Second):
		}

		current, err := s.client.GetMachineImage(s.config.ImageName)
		if err != nil {
			ui.Say(fmt.Sprintf("Waiting for image... (error: %v)", err))
			continue
		}

		ui.Say(fmt.Sprintf("Image state: %s", current.State))
		if current.State == "available" {
			ui.Say(fmt.Sprintf("Machine image '%s' is available!", current.Name))
			break
		}
		if current.State == "failed" || current.State == "error" {
			state.Put("error", fmt.Errorf("machine image creation failed: state=%s", current.State))
			return multistep.ActionHalt
		}
	}

	return multistep.ActionContinue
}

func (s *StepCreateImage) Cleanup(state multistep.StateBag) {}
