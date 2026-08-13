# frozen_string_literal: true

require_relative "../spec_helper"
require "tmpdir"

RSpec.describe InstanceAvailabilityFile do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  let(:path) { File.join(@tmpdir, "instance_availability.yml") }

  it "writes the given providers when the file does not exist" do
    described_class.merge_providers(path, {"gcp" => {"locations" => {}}})

    expect(YAML.load_file(path)).to eq({"providers" => {"gcp" => {"locations" => {}}}})
  end

  it "replaces only the given provider, leaving the others intact" do
    File.write(path, YAML.dump({"providers" => {
      "aws" => {"locations" => {"us-east-1" => {}}},
      "gcp" => {"locations" => {"gcp-old" => {}}},
    }}))

    described_class.merge_providers(path, {"gcp" => {"locations" => {"gcp-new" => {}}}})

    providers = YAML.load_file(path)["providers"]
    expect(providers["aws"]).to eq({"locations" => {"us-east-1" => {}}})
    expect(providers["gcp"]).to eq({"locations" => {"gcp-new" => {}}})
  end

  it "sorts provider keys so regenerating does not reorder the file" do
    File.write(path, YAML.dump({"providers" => {"gcp" => {}}}))

    described_class.merge_providers(path, {"aws" => {}})

    expect(YAML.load_file(path)["providers"].keys).to eq(["aws", "gcp"])
  end

  it "handles a file with no providers key" do
    File.write(path, YAML.dump({"unrelated" => true}))

    described_class.merge_providers(path, {"aws" => {}})

    data = YAML.load_file(path)
    expect(data["providers"].keys).to eq(["aws"])
    expect(data["unrelated"]).to be true
  end
end
