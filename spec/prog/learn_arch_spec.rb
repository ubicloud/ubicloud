# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnArch do
  subject(:la) { described_class.new(Strand.new) }

  let(:sshable) { instance_double(Sshable) }

  describe "#start" do
    it "exits, saving the architecture" do
      expect(sshable).to receive(:cmd).with("common/bin/arch").and_return("arm64")
      expect(la).to receive(:sshable).and_return(sshable)
      expect { la.start }.to exit(arch: "arm64")
    end

    it "fails when there's an unexpected architecture" do
      expect(sshable).to receive(:cmd).with("common/bin/arch").and_return("s390x")
      expect(la).to receive(:sshable).and_return(sshable)
      expect { la.start }.to raise_error RuntimeError, "BUG: unexpected CPU architecture"
    end
  end
end
