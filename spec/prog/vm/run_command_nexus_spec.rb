# frozen_string_literal: true

require "aws-sdk-ec2"
require "google/cloud/compute/v1"

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::RunCommandNexus do
  subject(:nx) { described_class.new(Strand.create(id: run_command.id, prog: "Vm::RunCommandNexus", label: "start")) }

  let(:vm) { create_vm(vm_host_id: create_vm_host.id) }
  let(:run_command) { RunCommand.create(vm_id: vm.id, command: "fetch_serial_log") }

  describe ".assemble" do
    it "creates a RunCommand and Strand for a known command" do
      st = described_class.assemble(vm_id: vm.id, command: "fetch_serial_log")
      expect(st.subject).to be_a RunCommand
      expect(st.subject.command).to eq "fetch_serial_log"
      expect(st.subject.status).to eq "created"
      expect(st.prog).to eq "Vm::RunCommandNexus"
      expect(st.label).to eq "start"
    end

    it "fails for an unregistered command" do
      expect { described_class.assemble(vm_id: vm.id, command: "rm -rf /") }.to raise_error RuntimeError, "Unknown run command: rm -rf /"
    end

    it "fails if the vm does not exist" do
      expect { described_class.assemble(vm_id: Vm.generate_uuid, command: "fetch_serial_log") }.to raise_error RuntimeError, "Vm does not exist"
    end
  end

  describe "#vm" do
    it "returns the vm associated with the run command" do
      expect(nx.vm).to eq vm
    end
  end

  describe "#start" do
    before { allow(nx).to receive(:vm).and_return(vm) }

    it "fetches the serial log over ssh for metal vms and stores it as succeeded" do
      expect(vm.vm_host.sshable).to receive(:_cmd).with("sudo tail -c 65536 /vm/#{vm.inhost_name}/serial.log").and_return("some serial output")

      expect { nx.start }.to exit({"msg" => "run command succeeded"})

      expect(run_command.reload.status).to eq "succeeded"
      expect(run_command.output).to eq "some serial output"
      expect(run_command.run_at).not_to be_nil
    end

    it "marks the run command as failed if it has no assigned host" do
      vm.update(vm_host_id: nil)

      expect { nx.start }.to exit({"msg" => "run command failed"})

      expect(run_command.reload.status).to eq "failed"
      expect(run_command.output).to eq "VM has no assigned host"
    end

    it "marks the run command as failed and logs if fetching raises" do
      expect(vm.vm_host.sshable).to receive(:_cmd).and_raise(Sshable::SshError.new("cmd", "", "boom", 1, nil))
      expect(Clog).to receive(:emit).with("run command failed", anything).and_call_original

      expect { nx.start }.to exit({"msg" => "run command failed"})

      expect(run_command.reload.status).to eq "failed"
    end
  end

  describe "#start with an unrecognized command" do
    let(:run_command) { RunCommand.create(vm_id: vm.id, command: "unknown") }

    before { allow(nx).to receive(:vm).and_return(vm) }

    it "marks the run command as failed" do
      expect { nx.start }.to exit({"msg" => "run command failed"})

      expect(run_command.reload.status).to eq "failed"
      expect(run_command.output).to eq "Unknown run command: unknown"
    end
  end

  describe "#start for aws vms" do
    let(:location) do
      Location.create(name: "us-west-2", provider: "aws", display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
    end
    let(:vm) do
      LocationCredentialAws.create_with_id(location, access_key: "test-access-key", secret_key: "test-secret-key")
      v = create_vm(location_id: location.id, vm_host_id: nil)
      AwsInstance.create_with_id(v, instance_id: "i-0123456789abcdefg")
      v
    end
    let(:client) { Aws::EC2::Client.new(stub_responses: true) }

    before do
      allow(nx).to receive(:vm).and_return(vm)
      allow(vm.location.location_credential_aws).to receive(:client).and_return(client)
    end

    it "fetches console output via the aws api" do
      client.stub_responses(:get_console_output, output: Base64.strict_encode64("aws serial output"))

      expect { nx.start }.to exit({"msg" => "run command succeeded"})

      expect(run_command.reload.output).to eq "aws serial output"
    end

    it "truncates output to the last MAX_OUTPUT_BYTES bytes" do
      long_output = "a" * (RunCommand::MAX_OUTPUT_BYTES + 100)
      client.stub_responses(:get_console_output, output: Base64.strict_encode64(long_output))

      expect { nx.start }.to exit({"msg" => "run command succeeded"})

      expect(run_command.reload.output.bytesize).to eq RunCommand::MAX_OUTPUT_BYTES
    end

    it "handles a vm with no console output yet" do
      client.stub_responses(:get_console_output, output: nil)

      expect { nx.start }.to exit({"msg" => "run command succeeded"})

      expect(run_command.reload.output).to eq ""
    end
  end

  describe "#start for gcp vms" do
    let(:location) do
      Location.create(name: "gcp-us-central1", provider: "gcp", display_name: "gcp-us-central1", ui_name: "GCP US Central 1", visible: true)
    end
    let(:vm) do
      LocationCredentialGcp.create_with_id(location, project_id: "test-gcp-project",
        service_account_email: "test@test-gcp-project.iam.gserviceaccount.com", credentials_json: "{}")
      location_az = LocationAz.create(location_id: location.id, az: "a")
      v = create_vm(location_id: location.id, vm_host_id: nil)
      VmGcpResource.create_with_id(v, location_az_id: location_az.id)
      v
    end
    let(:compute_client) { instance_double(Google::Cloud::Compute::V1::Instances::Rest::Client) }

    before do
      allow(nx).to receive(:vm).and_return(vm)
      allow(vm.location.location_credential_gcp).to receive(:compute_client).and_return(compute_client)
    end

    it "fetches serial port output via the gcp api" do
      expect(compute_client).to receive(:get_serial_port_output)
        .with(project: "test-gcp-project", zone: "us-central1-a", instance: vm.name)
        .and_return(Google::Cloud::Compute::V1::SerialPortOutput.new(contents: "gcp serial output"))

      expect { nx.start }.to exit({"msg" => "run command succeeded"})

      expect(run_command.reload.output).to eq "gcp serial output"
    end

    it "handles a vm with no serial port output yet" do
      expect(compute_client).to receive(:get_serial_port_output)
        .and_return(Google::Cloud::Compute::V1::SerialPortOutput.new)

      expect { nx.start }.to exit({"msg" => "run command succeeded"})

      expect(run_command.reload.output).to eq ""
    end
  end

  describe "#start for a vm on an unrecognized provider" do
    before do
      allow(nx).to receive(:vm).and_return(vm)
      allow(vm.location).to receive(:provider_dispatcher_group_name).and_return("unknown")
    end

    it "marks the run command as failed" do
      expect { nx.start }.to exit({"msg" => "run command failed"})

      expect(run_command.reload.status).to eq "failed"
      expect(run_command.output).to eq "Unsupported provider for serial console log: unknown"
    end
  end
end
