# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::LoadBalancer do
  describe ".serialize_internal" do
    it "serializes an lb correctly" do
      lb = instance_double(LoadBalancer, name: "test")
      ps = instance_double(PrivateSubnet, name: "test-ps")
      expect(lb).to receive(:private_subnet).and_return(ps)
      expect(ps).to receive(:display_location).and_return("hetzner")
      expect(lb).to receive(:ubid).and_return("1234")
      expect(lb).to receive(:hostname).and_return("something.com")
      expect(lb).to receive(:algorithm).and_return("roundrobin")
      expect(lb).to receive(:stack).and_return("dual")
      expect(lb).to receive(:health_check_endpoint).and_return("/")
      expect(lb).to receive(:health_check_protocol).and_return("tcp")
      expect(lb).to receive(:ports).and_return([]).twice

      expected_result = {
        id: "1234",
        name: "test",
        location: "hetzner",
        hostname: "something.com",
        algorithm: "roundrobin",
        stack: "dual",
        health_check_endpoint: "/",
        health_check_protocol: "tcp",
        src_port: nil,
        dst_port: nil
      }

      expect(described_class.serialize_internal(lb)).to eq(expected_result)
    end

    it "serializes an lb correctly2" do
      lb = instance_double(LoadBalancer, name: "test")
      ps = instance_double(PrivateSubnet, name: "test-ps")
      expect(lb).to receive(:private_subnet).and_return(ps)
      expect(ps).to receive(:display_location).and_return("hetzner")
      expect(lb).to receive(:ubid).and_return("1234")
      expect(lb).to receive(:hostname).and_return("something.com")
      expect(lb).to receive(:algorithm).and_return("roundrobin")
      expect(lb).to receive(:stack).and_return("dual")
      expect(lb).to receive(:health_check_endpoint).and_return("/")
      expect(lb).to receive(:health_check_protocol).and_return("tcp")
      expect(lb).to receive(:ports).and_return(nil).twice

      expected_result = {
        id: "1234",
        name: "test",
        location: "hetzner",
        hostname: "something.com",
        algorithm: "roundrobin",
        stack: "dual",
        health_check_endpoint: "/",
        health_check_protocol: "tcp",
        src_port: nil,
        dst_port: nil
      }

      expect(described_class.serialize_internal(lb)).to eq(expected_result)
    end
  end
end
