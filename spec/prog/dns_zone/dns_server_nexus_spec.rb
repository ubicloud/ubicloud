# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::DnsZone::DnsServerNexus do
  subject(:nx) { described_class.new(st) }

  let(:server) { DnsServer.create(name: "ns.example.com") }
  let(:st) { described_class.assemble(server) }

  it "creates one persistent strand without resetting existing progress" do
    refresh_frame(nx, new_values: {"saved_state" => true})
    expect(described_class.assemble(server).stack.first).to include("saved_state" => true)
    expect(server.strand.id).to eq st.id
  end

  it "waits when no configuration was requested" do
    expect(st.unsynchronized_run).to be_a(Prog::Base::Nap)
    expect(st.reload).to have_attributes(prog: "DnsZone::DnsServerNexus", label: "wait")
  end

  it "exits after the server is deleted" do
    st
    server.destroy
    expect { nx.before_run }.to exit("msg" => "dns server deleted")
  end
end
