# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Prog::Vm::PrepHost do
  describe "#start" do
    it "prepare host" do
      vm_host = Prog::Vm::HostNexus.assemble("::1").subject
      st = Strand.create(prog: "Vm::PrepHost", label: "start", stack: [{"subject_id" => vm_host.id}])
      ph = described_class.new(st)
      expect(ph.sshable).to receive(:_cmd).with("sudo host/bin/prep_host.rb #{vm_host.ubid} test")

      expect { ph.start }.to exit({"msg" => "host prepared"})
    end
  end
end
