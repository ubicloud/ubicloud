package ubicloud

import (
	"context"
	"fmt"

	"github.com/hashicorp/packer-plugin-sdk/multistep"
	packersdk "github.com/hashicorp/packer-plugin-sdk/packer"
)

// StepDestroyVM deletes the temporary builder VM.
type StepDestroyVM struct {
	client *Client
}

func (s *StepDestroyVM) Run(ctx context.Context, state multistep.StateBag) multistep.StepAction {
	return s.destroy(state)
}

func (s *StepDestroyVM) Cleanup(state multistep.StateBag) {
	s.destroy(state)
}

func (s *StepDestroyVM) destroy(state multistep.StateBag) multistep.StepAction {
	ui := state.Get("ui").(packersdk.Ui)

	vmNameRaw, ok := state.GetOk("vm_name")
	if !ok {
		return multistep.ActionContinue
	}
	vmName := vmNameRaw.(string)

	ui.Say(fmt.Sprintf("Destroying builder VM '%s'...", vmName))
	if err := s.client.DeleteVM(vmName); err != nil {
		ui.Error(fmt.Sprintf("Warning: could not delete VM '%s': %v", vmName, err))
	} else {
		ui.Say(fmt.Sprintf("Builder VM '%s' deleted.", vmName))
	}

	return multistep.ActionContinue
}
