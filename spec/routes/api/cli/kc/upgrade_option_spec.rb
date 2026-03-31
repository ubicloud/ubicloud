# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli kc upgrade-option" do
  before do
    expect(Config).to receive(:kubernetes_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "shows available upgrade option when cluster is not on the latest version" do
    cli(%W[kc eu-central-h1/test-kc create -c 1 -z standard-2 -w 1 -v #{Option.kubernetes_versions.last}])
    body = cli(%w[kc eu-central-h1/test-kc upgrade-option])
    expect(body).to eq(<<~OUTPUT)
      current-version: #{Option.kubernetes_versions.last}
      upgrade-version: #{Option.kubernetes_versions.first}
    OUTPUT
  end

  it "shows no upgrade option when cluster is on the latest version" do
    cli(%W[kc eu-central-h1/test-kc create -c 1 -z standard-2 -w 1 -v #{Option.kubernetes_versions.first}])
    body = cli(%w[kc eu-central-h1/test-kc upgrade-option])
    expect(body).to eq(<<~OUTPUT)
      current-version: #{Option.kubernetes_versions.first}
      upgrade-version: none
    OUTPUT
  end
end
