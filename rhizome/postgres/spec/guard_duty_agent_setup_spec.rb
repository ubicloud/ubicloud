# frozen_string_literal: true

require_relative "../lib/guard_duty_agent_setup"

RSpec.describe GuardDutyAgentSetup do
  subject(:setup) { described_class.new("eu-central-1") }

  let(:package_arch) { Arch.render(x64: "amd64", arm64: "arm64") }
  let(:url) { "https://323658145986-eu-central-1-guardduty-agent-deb-artifacts.s3.eu-central-1.amazonaws.com/1.17.1/#{package_arch}/amazon-guardduty-agent-1.17.1.#{package_arch}.deb" }

  def expect_installed_version(version)
    expect(setup).to receive(:_run_command).with("dpkg-query", "--show", "--showformat=${Version}", "amazon-guardduty-agent", expect: [0, 1]).and_return(version)
  end

  def expect_install
    packages = []
    expect(setup).to receive(:curl_file).with(url, end_with("/amazon-guardduty-agent.deb")) do |_, path|
      packages << path
      described_class::CHECKSUM
    end
    expect(setup).to receive(:_run_command).with("dpkg", "-i", anything) do |_, _, path|
      packages << path
      ""
    end
    packages
  end

  describe "#run" do
    it "leaves the pinned version in place" do
      expect_installed_version("1.17.1")
      expect(setup).not_to receive(:curl_file)
      setup.run
    end

    it "installs the agent from the region's bucket when it is missing" do
      expect_installed_version("")
      packages = expect_install
      setup.run
      expect(packages.uniq.size).to eq 1
    end

    it "replaces another installed version" do
      expect_installed_version("1.9.2")
      expect_install
      setup.run
    end

    it "fails without installing when the download has the wrong digest" do
      expect_installed_version("")
      expect(setup).to receive(:curl_file).with(url, end_with("/amazon-guardduty-agent.deb")).and_return("wrongsha256")
      expect { setup.run }.to raise_error(RuntimeError, "Invalid SHA-256 digest")
    end

    it "fails for a region without a known bucket" do
      setup = described_class.new("mars-north-1")
      expect(setup).to receive(:_run_command).with("dpkg-query", "--show", "--showformat=${Version}", "amazon-guardduty-agent", expect: [0, 1]).and_return("")
      expect { setup.run }.to raise_error(KeyError, /mars-north-1/)
    end
  end
end
