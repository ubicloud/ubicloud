# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::InstallRhizome do
  subject(:ir) { described_class.new(Strand.new(stack: [{sshable_id: "bogus"}])) }

  let(:sshable) { instance_double(Sshable) }

  before do
    expect(ir).to receive(:sshable).and_return(sshable).at_least(:once)
  end

  describe "#start" do
    it "writes tar" do
      expect(sshable).to receive(:cmd) do |*args, **kwargs|
        expect(args).to eq ["tar xf -"]

        # Take offset from
        # https://www.gnu.org/software/tar/manual/html_node/Standard.html
        expect(kwargs[:stdin][257..261]).to eq "ustar"
      end
      expect { ir.start }.to hop("install_gems")
    end
  end

  describe "#install_gems" do
    it "runs some commands and exits" do
      expect(sshable).to receive(:cmd).with("bundle config set --local path vendor/bundle")
      expect(sshable).to receive(:cmd).with("bundle install")
      expect { ir.install_gems }.to raise_error Prog::Base::Exit do |ex|
        expect(ex.exitval).to eq({"msg" => "installed rhizome"})
      end
    end
  end
end
