package ubicloud

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/hashicorp/packer-plugin-sdk/multistep"
	packersdk "github.com/hashicorp/packer-plugin-sdk/packer"
	"golang.org/x/crypto/ssh"
)

// StepCreateVM creates the temporary builder VM.
type StepCreateVM struct {
	config *Config
	client *Client
	vmName string
}

func (s *StepCreateVM) Run(ctx context.Context, state multistep.StateBag) multistep.StepAction {
	ui := state.Get("ui").(packersdk.Ui)

	s.vmName = s.config.TempVMName()
	ui.Say(fmt.Sprintf("Creating builder VM '%s' in %s...", s.vmName, s.config.Location))

	// Get the SSH public key that packer will use to connect.
	// It may be pre-populated (e.g. generated temp key), or we derive it from the private key file.
	sshPublicKey := string(s.config.Comm.SSH.SSHPublicKey)
	if sshPublicKey == "" {
		keyFile := s.config.Comm.SSH.SSHPrivateKeyFile
		if keyFile == "" {
			state.Put("error", fmt.Errorf("no SSH public key available and no ssh_private_key_file configured"))
			return multistep.ActionHalt
		}
		// Expand ~ in path
		if strings.HasPrefix(keyFile, "~/") {
			home, err := os.UserHomeDir()
			if err != nil {
				state.Put("error", fmt.Errorf("resolving home dir: %w", err))
				return multistep.ActionHalt
			}
			keyFile = filepath.Join(home, keyFile[2:])
		}
		pubKey, err := derivePublicKey(keyFile)
		if err != nil {
			state.Put("error", fmt.Errorf("deriving public key from %s: %w", keyFile, err))
			return multistep.ActionHalt
		}
		sshPublicKey = pubKey
	}

	req := CreateVMRequest{
		PublicKey:   sshPublicKey,
		Size:        s.config.VMSize,
		Arch:        s.config.VMArch,
		StorageSize: s.config.StorageSize,
		BootImage:   s.config.BootImage,
	}

	vm, err := s.client.CreateVM(s.vmName, req)
	if err != nil {
		state.Put("error", fmt.Errorf("creating VM: %w", err))
		return multistep.ActionHalt
	}

	state.Put("vm_name", s.vmName)
	state.Put("vm_id", vm.ID)
	ui.Say(fmt.Sprintf("Builder VM '%s' created (ID: %s)", s.vmName, vm.ID))
	return multistep.ActionContinue
}

func (s *StepCreateVM) Cleanup(state multistep.StateBag) {
	// VM cleanup is handled by StepDestroyVM
}

// derivePublicKey reads an SSH private key file and returns the authorized_keys format public key.
func derivePublicKey(privateKeyFile string) (string, error) {
	data, err := os.ReadFile(privateKeyFile)
	if err != nil {
		return "", fmt.Errorf("read private key file: %w", err)
	}
	signer, err := ssh.ParsePrivateKey(data)
	if err != nil {
		return "", fmt.Errorf("parse private key: %w", err)
	}
	pubKey := string(ssh.MarshalAuthorizedKey(signer.PublicKey()))
	return strings.TrimSpace(pubKey), nil
}
