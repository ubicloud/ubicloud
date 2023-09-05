# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::InstallRhizome do
  subject(:ir) { described_class.new(Strand.new(stack: [{"target_folder" => "host"}])) }

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
      expect(sshable).to receive(:cmd).with("bundle install --gemfile common/Gemfile --path common/vendor/bundle")
      expect(sshable).to receive(:cmd).with("bundle install --gemfile host/Gemfile --path host/vendor/bundle")
      expect { ir.install_gems }.to exit({"msg" => "installed rhizome"})
    end

    it "does not install gems if there is no Gemfile" do
      expect(File).to receive(:exist?).and_return(false)
      expect(sshable).to receive(:cmd).with("bundle install --gemfile common/Gemfile --path common/vendor/bundle")
      expect(sshable).not_to receive(:cmd).with("bundle install --gemfile host/Gemfile --path host/vendor/bundle")
      expect { ir.install_gems }.to exit({"msg" => "installed rhizome"})
    end
  end
end
