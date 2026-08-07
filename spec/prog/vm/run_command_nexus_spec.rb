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

    it "fails synchronously with a client error if the vm has no assigned host" do
      vm.update(vm_host_id: nil)
      expect { described_class.assemble(vm_id: vm.id, command: "fetch_serial_log") }.to raise_error(CloverError) { |ex|
        expect(ex.code).to eq 400
        expect(ex.message).to eq "VM has no assigned host"
      }
    end

    it "does not require an assigned host for a non-metal vm" do
      location = Location.create(name: "us-west-2", provider: "aws", display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
      aws_vm = create_vm(location_id: location.id, vm_host_id: nil)

      expect { described_class.assemble(vm_id: aws_vm.id, command: "fetch_serial_log") }.not_to raise_error
    end

    it "reuses the existing run's row for the same vm and command once the previous run has finished" do
      first = described_class.assemble(vm_id: vm.id, command: "fetch_serial_log").subject
      # A root Strand self-reaps on exit; simulate a finished run the same
      # way, rather than a run that's merely marked done without its
      # Strand ever actually completing.
      first.strand.destroy
      first.update(status: "succeeded", output: "old output", run_at: Time.now, created_at: Time.now - 3600)
      old_created_at = first.created_at

      second = described_class.assemble(vm_id: vm.id, command: "fetch_serial_log").subject

      expect(second.id).to eq first.id
      expect(second.status).to eq "created"
      expect(second.output).to be_nil
      expect(second.created_at).to be > old_created_at
      expect(RunCommand.where(vm_id: vm.id, command: "fetch_serial_log").count).to eq 1
      expect(Strand.where(id: first.id).count).to eq 1
    end

    it "leaves an in-flight run alone instead of pulling its strand's lease out from under it" do
      first = described_class.assemble(vm_id: vm.id, command: "fetch_serial_log").subject

      second = described_class.assemble(vm_id: vm.id, command: "fetch_serial_log")

      expect(second).to eq first.strand
      expect(RunCommand.where(vm_id: vm.id, command: "fetch_serial_log").count).to eq 1
      expect(Strand.where(id: first.id).count).to eq 1
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

    it "retries a retryable error a limited number of times, then fails without exposing the exception message" do
      expect(vm.vm_host.sshable).to receive(:_cmd).exactly(described_class::MAX_ATTEMPTS).times
        .and_raise(Sshable::SshError.new("cmd", "", "boom", 1, nil))
      expect(Clog).to receive(:emit).with("run command failed, retrying", anything).twice.and_call_original
      expect(Clog).to receive(:emit).with("run command failed", anything).and_call_original

      (described_class::MAX_ATTEMPTS - 1).times do |i|
        expect { nx.start }.to nap(described_class::RETRY_NAP_SECONDS)
        expect(run_command.reload.status).to eq "created"
      end

      expect { nx.start }.to exit({"msg" => "run command failed"})
      expect(run_command.reload.status).to eq "failed"
      expect(run_command.output).to be_nil
    end

    it "retries on an SSH connection-level failure the same as a command failure" do
      expect(vm.vm_host.sshable).to receive(:_cmd).and_raise(Errno::ECONNREFUSED)

      expect { nx.start }.to nap(described_class::RETRY_NAP_SECONDS)
      expect(run_command.reload.status).to eq "created"
    end
  end

  describe "#start with an unrecognized command" do
    let(:run_command) { RunCommand.create(vm_id: vm.id, command: "unknown") }

    before { allow(nx).to receive(:vm).and_return(vm) }

    it "raises instead of silently storing a failed result, since assemble should never allow this" do
      expect { nx.start }.to raise_error NoMethodError
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
end
