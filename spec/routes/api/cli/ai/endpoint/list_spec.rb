# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "cli ai endpoint list" do
  let(:ps) { Prog::Vnet::SubnetNexus.assemble(@project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject }

  let(:lb) do
    lb = LoadBalancer.create(private_subnet_id: ps.id, name: "dummy-lb-1", health_check_endpoint: "/up", project_id: @project.id)
    LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 80, dst_port: 8000)
    lb
  end

  let(:ie) do
    InferenceEndpoint.create(
      name: "test-model", model_name: "test-model", project_id: @project.id,
      is_public: true, visible: true, load_balancer_id: lb.id,
      location_id: Location::HETZNER_FSN1_ID, vm_size: "size",
      replica_count: 1, boot_image: "image", storage_volumes: [],
      engine_params: "", engine: "vllm", private_subnet_id: ps.id,
      tags: {"capability" => "Text Generation", "display_name" => "Test Model", "hf_model" => "test-org/test-model"},
    )
  end

  it "shows empty list" do
    expect(cli(%w[ai endpoint list -N])).to eq "\n"
  end

  it "shows list of inference endpoints" do
    ie

    expect(cli(%w[ai endpoint list -N])).to eq "test-model  Text Generation      0.05  0.05\n"
  end

  it "-f name option shows only name" do
    ie

    expect(cli(%w[ai endpoint list -Nfname])).to eq "test-model\n"
  end

  it "headers are shown by default" do
    ie

    expect(cli(%w[ai endpoint list])).to eq \
      "name        capability       multimodal  context-length  input-price  output-price\n" \
      "test-model  Text Generation                              0.05         0.05        \n"
  end
end
