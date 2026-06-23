# frozen_string_literal: true

require_relative "../model/spec_helper"
require_relative "../../demo/cloudify_server_cli"

RSpec.describe CloudifyServer do
  before do
    described_class.instance_variable_set(:@locations, nil)
  end

  after do
    described_class.instance_variable_set(:@locations, nil)
  end

  describe ".location_label" do
    it "formats a location label" do
      location = instance_double(
        Location,
        provider: HostProvider::HETZNER_PROVIDER_NAME,
        name: "fsn1",
        display_name: "Falkenstein",
      )

      expect(described_class.location_label(location)).to eq("hetzner fsn1 (Falkenstein)")
    end
  end

  describe ".locations" do
    it "memoizes visible locations" do
      visible_locations = Location.where(visible: true).all
      expected = visible_locations.to_h { |location| [location, described_class.location_label(location)] }

      expect(Location).to receive(:where).with(visible: true).once.and_call_original

      expect(described_class.locations).to eq(expected)
      expect(described_class.locations).to eq(expected)
    end
  end

  describe ".get_input" do
    it "re-prompts until a non-empty value is provided" do
      allow(described_class).to receive(:gets).and_return("\n", "1.2.3.4\n")

      expect {
        expect(described_class.get_input("Enter host IP address")).to eq("1.2.3.4")
      }.to output("Enter host IP address: Enter host IP address: ").to_stdout
    end

    it "uses the default when the input is empty" do
      allow(described_class).to receive(:gets).and_return("\n")

      expect {
        expect(described_class.get_input("Enter host identifier", "321")).to eq("321")
      }.to output("Enter host identifier [default: 321]: ").to_stdout
    end
  end

  describe ".select_option" do
    let(:options) { {alpha: "Alpha", beta: "Beta"} }

    it "accepts the default selection" do
      allow(described_class).to receive(:gets).and_return("\n")

      expect {
        expect(described_class.select_option("Select option", options, 1)).to eq(:alpha)
      }.to output(/\A\n1\. Alpha\n2\. Beta\n\nSelect option \[default: 1\]: \z/).to_stdout
    end

    it "re-prompts after an invalid value" do
      allow(described_class).to receive(:gets).and_return("0\n", "2\n")

      expect {
        expect(described_class.select_option("Select option", options)).to eq(:beta)
      }.to output(/\A\n1\. Alpha\n2\. Beta\n\nSelect option: Please enter a number between 1-2\nSelect option: \z/).to_stdout
    end

    it "includes the default hint when re-prompting after an invalid value" do
      allow(described_class).to receive(:gets).and_return("0\n", "\n")

      expect {
        expect(described_class.select_option("Select option", options, 1)).to eq(:alpha)
      }.to output(/\A\n1\. Alpha\n2\. Beta\n\nSelect option \[default: 1\]: Please enter a number between 1-2 or leave empty for default\nSelect option \[default: 1\]: \z/).to_stdout
    end
  end

  describe ".required_env_vars_configured?" do
    it "returns true when all required variables are configured" do
      allow(Config).to receive(:public_send).and_return("set")

      expect(described_class.required_env_vars_configured?).to be true
    end

    it "returns false when one of the required variables is missing" do
      allow(Config).to receive(:public_send) do |name|
        if name.to_s == "hetzner_password"
          nil
        else
          "set"
        end
      end

      expect(described_class.required_env_vars_configured?).to be false
    end
  end

  describe ".hetzner_api" do
    it "builds a Hetzner API client from config" do
      api = instance_double(Hosting::HetznerApis)

      expect(Hosting::HetznerApis).to receive(:new) do |config|
        expect(config.connection_string).to eq(Config.hetzner_connection_string)
        expect(config.user).to eq(Config.hetzner_user)
        expect(config.password).to eq(Config.hetzner_password)
        api
      end

      expect(described_class.hetzner_api).to eq(api)
    end
  end

  describe ".find_hetzner_server_identifier" do
    it "delegates the lookup to the Hetzner API wrapper" do
      api = instance_double(Hosting::HetznerApis)

      expect(described_class).to receive(:hetzner_api).and_return(api)
      expect(api).to receive(:find_server_identifier).with("1.2.3.4").and_return("321")

      expect(described_class.find_hetzner_server_identifier("1.2.3.4")).to eq("321")
    end
  end

  describe ".vm_host_dataset" do
    it "filters vm hosts by hostname, server identifier, provider, and location" do
      location = instance_double(
        Location,
        provider: HostProvider::HETZNER_PROVIDER_NAME,
        id: "location-id",
      )
      sshable_ds = instance_double(Sequel::Dataset)
      provider_ds = instance_double(Sequel::Dataset)
      vm_host_ds = instance_double(Sequel::Dataset)

      expect(Sshable).to receive(:where).with(host: "1.2.3.4").and_return(sshable_ds)
      expect(sshable_ds).to receive(:select).with(:id).and_return(:sshable_ids)
      expect(HostProvider).to receive(:where).with(
        server_identifier: "321",
        provider_name: HostProvider::HETZNER_PROVIDER_NAME,
      ).and_return(provider_ds)
      expect(provider_ds).to receive(:select).with(:id).and_return(:provider_ids)
      expect(VmHost).to receive(:where).with(id: :sshable_ids).and_return(vm_host_ds)
      expect(vm_host_ds).to receive(:where).with(id: :provider_ids).and_return(vm_host_ds)
      expect(vm_host_ds).to receive(:where).with(location_id: location.id).and_return(vm_host_ds)

      expect(described_class.vm_host_dataset("1.2.3.4", "321", location)).to eq(vm_host_ds)
    end
  end

  describe ".get_host_identifier" do
    let(:hostname) { "1.2.3.4" }

    it "returns the automatically discovered Hetzner server identifier" do
      location = double(provider: HostProvider::HETZNER_PROVIDER_NAME)

      expect(described_class).to receive(:find_hetzner_server_identifier).with(hostname).and_return("321")
      expect(described_class).not_to receive(:get_input)

      expect {
        expect(described_class.get_host_identifier(hostname, location)).to eq("321")
      }.to output("Found Hetzner server identifier '321' for '#{hostname}'\n").to_stdout
    end

    it "falls back to manual input when auto-discovery does not find a server" do
      location = double(provider: HostProvider::HETZNER_PROVIDER_NAME)

      expect(described_class).to receive(:find_hetzner_server_identifier).with(hostname).and_return(nil)
      expect(described_class).to receive(:get_input).with("Enter host identifier").and_return("654")

      expect {
        expect(described_class.get_host_identifier(hostname, location)).to eq("654")
      }.to output("Couldn't find the Hetzner server identifier automatically for '#{hostname}'.\n").to_stdout
    end

    it "uses manual input for non-Hetzner providers" do
      location = double(provider: HostProvider::AWS_PROVIDER_NAME)

      expect(described_class).not_to receive(:find_hetzner_server_identifier)
      expect(described_class).to receive(:get_input).with("Enter host identifier").and_return("789")

      expect(described_class.get_host_identifier(hostname, location)).to eq("789")
    end
  end

  describe ".run" do
    let(:hostname) { "1.2.3.4" }
    let(:host_id) { "321" }
    let(:location) {
      double(
        provider: HostProvider::HETZNER_PROVIDER_NAME,
        id: "location-id",
      )
    }
    let(:locations) { {location => "hetzner fsn1 (Falkenstein)"} }
    let(:vm_host_ds) { instance_double(Sequel::Dataset) }

    before do
      allow(described_class).to receive(:locations).and_return(locations)
      allow(described_class).to receive(:get_input).with("Enter host IP address").and_return(hostname)
      allow(described_class).to receive(:select_option).with("Select provider and location", locations, 1).and_return(location)
      allow(described_class).to receive(:get_host_identifier).with(hostname, location).and_return(host_id)
      allow(described_class).to receive(:vm_host_dataset).with(hostname, host_id, location).and_return(vm_host_ds)
      allow(Time).to receive(:now).and_return(Time.utc(2026, 4, 10, 12, 0, 0))
      allow(described_class).to receive(:sleep)
    end

    it "exits when the required environment variables are missing" do
      allow(described_class).to receive(:required_env_vars_configured?).and_return(false)
      allow(described_class).to receive(:exit).with(1).and_raise(SystemExit.new(1))

      expect {
        expect { described_class.run }.to raise_error(SystemExit)
      }.to output(
        "Please set the following variables in the .env file and re-run docker-compose up:\n" \
        "#{described_class::REQUIRED_ENV_VARS.join("\n")}\n",
      ).to_stdout
    end

    it "exits when a non-Hetzner location is selected" do
      other_location = double(provider: HostProvider::AWS_PROVIDER_NAME, id: "aws-location")
      allow(described_class).to receive_messages(
        required_env_vars_configured?: true,
        locations: {other_location => "aws us-east-1 (N. Virginia)"},
        select_option: other_location,
      )
      allow(described_class).to receive(:get_host_identifier).with(hostname, other_location).and_return("aws-host-id")
      allow(described_class).to receive(:exit).with(1).and_raise(SystemExit.new(1))

      expect {
        expect { described_class.run }.to raise_error(SystemExit)
      }.to output(
        /Cloudifying '1\.2\.3\.4' server for 'aws us-east-1 \(N\. Virginia\)'.*Currently only Hetzner is supported for this demo\. Please use a Hetzner server for cloudification\.\n/m,
      ).to_stdout
    end

    it "reuses the existing strand for an already cloudified server" do
      allow(described_class).to receive(:required_env_vars_configured?).and_return(true)
      allow(vm_host_ds).to receive(:first).and_return(
        double(id: "vm-host-id", strand: double),
      )
      strand = vm_host_ds.first.strand
      expect(strand).to receive(:reload).and_return(
        double(label: "setup"),
        double(label: "setup"),
        double(label: "wait"),
      )
      expect(described_class).to receive(:sleep).with(2).twice
      expect(Timeout).to receive(:timeout).with(30 * 60).and_yield

      expect {
        described_class.run
      }.to output(
        /Cloudifying '1\.2\.3\.4' server for 'hetzner fsn1 \(Falkenstein\)'.*Found existing cloudified server for '1\.2\.3\.4' with ID: vm-host-id.*Waiting for server to be cloudified.*2026-04-10 12:00:00 UTC state: setup.*Your server is cloudified now\. You can create virtual machines at 'hetzner fsn1 \(Falkenstein\)' in the cloud dashboard\.\n/m,
      ).to_stdout
    end

    it "assembles a new strand when the server is not cloudified yet" do
      allow(described_class).to receive(:required_env_vars_configured?).and_return(true)
      allow(vm_host_ds).to receive(:first).and_return(nil)
      strand = double
      expect(Prog::Vm::HostNexus).to receive(:assemble).with(
        hostname,
        provider_name: location.provider,
        server_identifier: host_id,
        location_id: location.id,
        default_boot_images: ["ubuntu-noble"],
      ).and_return(strand)
      expect(strand).to receive(:reload).and_return(double(label: "wait"))
      expect(Timeout).to receive(:timeout).with(30 * 60).and_yield

      expect {
        described_class.run
      }.to output(
        /Cloudifying '1\.2\.3\.4' server for 'hetzner fsn1 \(Falkenstein\)'.*Waiting for server to be cloudified.*Your server is cloudified now\. You can create virtual machines at 'hetzner fsn1 \(Falkenstein\)' in the cloud dashboard\.\n/m,
      ).to_stdout
    end

    it "reports a timeout while cloudifying a server" do
      allow(described_class).to receive(:required_env_vars_configured?).and_return(true)
      allow(vm_host_ds).to receive(:first).and_return(nil)
      strand = double(label: "download_boot_image", id: "strand-id")
      allow(Prog::Vm::HostNexus).to receive(:assemble).and_return(strand)
      allow(Timeout).to receive(:timeout).with(30 * 60).and_raise(Timeout::Error)
      allow(described_class).to receive(:exit).with(1).and_raise(SystemExit.new(1))

      expect {
        expect { described_class.run }.to raise_error(SystemExit)
      }.to output(
        /Cloudifying '1\.2\.3\.4' server for 'hetzner fsn1 \(Falkenstein\)'.*Could not cloudify server in 30 minutes\. Probably something went wrong\..*Last state: download_boot_image\. Server ID for debug: strand-id.*Please check your hostname\/IP address and be sure that you added the correct public SSH key to your server\..*You can ask for help on GitHub discussion page: https:\/\/github\.com\/ubicloud\/ubicloud\/discussions\n/m,
      ).to_stdout
    end
  end
end
