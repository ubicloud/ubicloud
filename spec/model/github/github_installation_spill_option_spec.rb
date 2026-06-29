# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GithubInstallationSpillOption do
  subject(:spill_option) {
    described_class.create(vcpus_limit: 300) { it.id = installation.id }
  }

  let(:installation) {
    GithubInstallation.create(installation_id: 123, project_id: Project.create(name: "default").id, name: "test-user", type: "User")
  }

  it "shares its id with the installation it belongs to" do
    expect(spill_option.id).to eq(installation.id)
    expect(spill_option.installation).to eq(installation)
    expect(installation.spill_option).to eq(spill_option)
  end

  it "defaults spill_ratio and allocated_vcpus to zero" do
    expect(spill_option.spill_ratio).to eq(0)
    expect(spill_option.allocated_vcpus).to eq(0)
  end

  it "is destroyed together with the installation" do
    spill_option
    installation.destroy
    expect(described_class[installation.id]).to be_nil
  end
end
