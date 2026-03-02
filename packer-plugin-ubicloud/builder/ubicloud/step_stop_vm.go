package ubicloud

import (
	"context"
	"fmt"
	"time"

	"github.com/hashicorp/packer-plugin-sdk/multistep"
	packersdk "github.com/hashicorp/packer-plugin-sdk/packer"
)

// StepStopVM stops the builder VM via API.
type StepStopVM struct {
	client *Client
}

func (s *StepStopVM) Run(ctx context.Context, state multistep.StateBag) multistep.StepAction {
	ui := state.Get("ui").(packersdk.Ui)
	vmName := state.Get("vm_name").(string)

	ui.Say("Stopping VM...")
	if err := s.client.StopVM(vmName); err != nil {
		state.Put("error", fmt.Errorf("stopping VM: %w", err))
		return multistep.ActionHalt
	}

	ui.Say("Waiting for VM to stop...")
	timeout := 5 * time.Minute
	start := time.Now()

	for {
		if time.Since(start) > timeout {
			state.Put("error", fmt.Errorf("timeout waiting for VM to stop"))
			return multistep.ActionHalt
		}

		select {
		case <-ctx.Done():
			state.Put("error", ctx.Err())
			return multistep.ActionHalt
		case <-time.After(10 * time.Second):
		}

		vm, err := s.client.GetVM(vmName)
		if err != nil {
			ui.Say(fmt.Sprintf("Waiting for VM to stop... (error: %v)", err))
			continue
		}

		ui.Say(fmt.Sprintf("VM state: %s", vm.State))
		if vm.State == "stopped" {
			break
		}
	}

	ui.Say("VM stopped.")
	return multistep.ActionContinue
}

func (s *StepStopVM) Cleanup(state multistep.StateBag) {}
