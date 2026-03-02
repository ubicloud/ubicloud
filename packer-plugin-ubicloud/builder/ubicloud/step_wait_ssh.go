package ubicloud

import (
	"context"
	"fmt"
	"time"

	"github.com/hashicorp/packer-plugin-sdk/multistep"
	packersdk "github.com/hashicorp/packer-plugin-sdk/packer"
)

// StepWaitSSH waits for the VM to become running and sets SSH connection info.
type StepWaitSSH struct {
	config *Config
	client *Client
}

func (s *StepWaitSSH) Run(ctx context.Context, state multistep.StateBag) multistep.StepAction {
	ui := state.Get("ui").(packersdk.Ui)
	vmName := state.Get("vm_name").(string)

	ui.Say("Waiting for VM to become running...")

	timeout := 10 * time.Minute
	start := time.Now()

	var vm *VM
	for {
		if time.Since(start) > timeout {
			state.Put("error", fmt.Errorf("timeout waiting for VM to become running"))
			return multistep.ActionHalt
		}

		select {
		case <-ctx.Done():
			state.Put("error", ctx.Err())
			return multistep.ActionHalt
		case <-time.After(10 * time.Second):
		}

		var err error
		vm, err = s.client.GetVM(vmName)
		if err != nil {
			ui.Say(fmt.Sprintf("Waiting for VM... (error: %v)", err))
			continue
		}

		ui.Say(fmt.Sprintf("VM state: %s", vm.State))
		if vm.State == "running" {
			break
		}
	}

	// Set IPv6 as the SSH host (VMs are accessed via IPv6 through the host proxy)
	sshHost := vm.IP6
	if sshHost == "" {
		sshHost = vm.IP4
	}
	if sshHost == "" {
		state.Put("error", fmt.Errorf("VM has no IP address"))
		return multistep.ActionHalt
	}

	ui.Say(fmt.Sprintf("VM is running at %s", sshHost))
	state.Put("ssh_host", sshHost)
	state.Put("vm_ip", sshHost)

	return multistep.ActionContinue
}

func (s *StepWaitSSH) Cleanup(state multistep.StateBag) {}
