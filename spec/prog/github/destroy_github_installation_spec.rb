# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "octokit"

RSpec.describe Prog::Github::DestroyGithubInstallation do
  subject(:dgi) {
    described_class.new(Strand.new).tap {
      it.instance_variable_set(:@github_installation, github_installation)
    }
  }

  let(:github_installation) { GithubInstallation.new(name: "ubicloud", type: "Organization", installation_id: "123") }

  describe ".assemble" do
    it "creates a strand" do
      expect { described_class.assemble(github_installation) }.to change(Strand, :count).from(0).to(1)
    end
  end

  describe ".before_run" do
    it "pops if installation already deleted" do
      expect(dgi).to receive(:github_installation).and_return(nil)
      expect { dgi.before_run }.to exit({"msg" => "github installation is destroyed"})
    end

    it "no ops if installation exists" do
      expect(dgi).to receive(:github_installation).and_return(github_installation)
      dgi.before_run
    end
  end

  describe "#start" do
    it "hops after registering deadline" do
      expect(dgi).to receive(:register_deadline)
      expect { dgi.start }.to hop("delete_installation")
    end
  end

  describe "#delete_installation" do
    before do
      allow(Github).to receive(:app_client).and_return(instance_double(Octokit::Client))
    end

    it "hops after deleting installation from GitHub" do
      expect(Github.app_client).to receive(:delete_installation).with(github_installation.installation_id)
      expect { dgi.delete_installation }.to hop("destroy_resources")
    end

    it "hops if even the installation not found" do
      expect(Github.app_client).to receive(:delete_installation).with(github_installation.installation_id).and_raise(Octokit::NotFound)
      expect { dgi.delete_installation }.to hop("destroy_resources")
    end
  end

  describe "#destroy_resources" do
    it "hops after incrementing destroy for repositories and runners" do
      repository = instance_double(GithubRepository)
      runner = instance_double(GithubRunner)
      expect(repository).to receive(:incr_destroy)
      expect(runner).to receive(:incr_skip_deregistration)
      expect(runner).to receive(:incr_destroy)
      expect(github_installation).to receive(:repositories).and_return([repository])
      expect(github_installation).to receive(:runners).and_return([runner])

      expect { dgi.destroy_resources }.to hop("wait_resource_destroy")
    end
  end

  describe "#wait_resource_destroy" do
    it "naps if not all runners destroyed" do
      expect(github_installation).to receive(:runners_dataset).and_return(instance_double(Sequel::Dataset, empty?: false))
      expect { dgi.wait_resource_destroy }.to nap(10)
    end

    it "naps if not all repositories destroyed" do
      expect(github_installation).to receive(:runners_dataset).and_return(instance_double(Sequel::Dataset, empty?: true))
      expect(github_installation).to receive(:repositories_dataset).and_return(instance_double(Sequel::Dataset, empty?: false))
      expect { dgi.wait_resource_destroy }.to nap(10)
    end

    it "deletes resource and pops" do
      expect(github_installation).to receive(:runners_dataset).and_return(instance_double(Sequel::Dataset, empty?: true))
      expect(github_installation).to receive(:repositories_dataset).and_return(instance_double(Sequel::Dataset, empty?: true))
      expect(github_installation).to receive(:destroy)
      expect { dgi.wait_resource_destroy }.to exit({"msg" => "github installation destroyed"})
    end
  end
end
