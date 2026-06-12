# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::LoadBalancer do
  describe ".serialize_internal" do
    let(:project) { Project.create(name: "test-project") }
    let(:ps) {
      PrivateSubnet.create(name: "test-ps", project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID, net4: "10.0.0.0/26", net6: "fdfa::/64")
    }
    let(:lb) {
      LoadBalancer.create(
        name: "test", project_id: project.id, private_subnet_id: ps.id,
        custom_hostname: "something.com",
        health_check_endpoint: "/", health_check_protocol: "tcp",
        algorithm: "round_robin", stack: "dual",
      )
    }

    it "serializes an lb correctly" do
      LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 1, dst_port: 5)

      expected_result = {
        id: lb.ubid,
        name: "test",
        location: "eu-central-h1",
        hostname: "something.com",
        algorithm: "round_robin",
        stack: "dual",
        health_check_endpoint: "/",
        health_check_protocol: "tcp",
        src_port: 1,
        dst_port: 5,
        cert_enabled: false,
      }

      expect(described_class.serialize_internal(lb.reload)).to eq(expected_result)
    end

    it "serializes an lb correctly2" do
      expected_result = {
        id: lb.ubid,
        name: "test",
        location: "eu-central-h1",
        hostname: "something.com",
        algorithm: "round_robin",
        stack: "dual",
        health_check_endpoint: "/",
        health_check_protocol: "tcp",
        src_port: nil,
        dst_port: nil,
        cert_enabled: false,
      }

      expect(described_class.serialize_internal(lb)).to eq(expected_result)
    end
  end
end
