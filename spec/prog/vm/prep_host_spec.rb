# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Prog::Vm::PrepHost do
  subject(:ph) {
    described_class.new(Strand.new)
  }

  describe "#start" do
    it "prepare host" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with("sudo host/bin/prep_host.rb")
      expect(ph).to receive(:sshable).and_return(sshable)

      expect { ph.start }.to exit({"msg" => "host prepared"})
    end
  end
end
