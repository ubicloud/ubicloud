# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::InstallRhizome do
  subject(:ir) { described_class.new(Strand.new(stack: [{"target_folder" => "host"}])) }

  let(:sshable) { Sshable.new }

  before do
    allow(ir).to receive(:sshable).and_return(sshable)
  end

  it "exits if destroy is set" do
    expect(ir.before_run).to be_nil
    expect(ir).to receive(:when_destroy_set?).and_yield
    expect { ir.before_run }.to exit({"msg" => "exiting early due to destroy semaphore"})
  end

  describe "#start" do
    it "writes tar" do
      expect(sshable).to receive(:_cmd) do |*args, **kwargs|
        expect(args).to eq ["tar xf -"]

        expect(kwargs[:stdin].scan("Gemfile.lock").count).to be < 2

        # Take offset from
        # https://www.gnu.org/software/tar/manual/html_node/Standard.html
        expect(kwargs[:stdin][257..261]).to eq "ustar"
      end
      expect { ir.start }.to hop("install_gems")
    end

    it "writes tar including specs" do
      ir_spec = described_class.new(Strand.new(stack: [{"target_folder" => "host", "install_specs" => true}]))
      expect(ir_spec).to receive(:sshable).and_return(sshable).at_least(:once)
      expect(sshable).to receive(:_cmd)
      expect { ir_spec.start }.to hop("install_gems")
    end
  end

  describe "#install_gems" do
    it "runs some commands and exits" do
      expect(sshable).to receive(:_cmd).with("bundle config set --local path vendor/bundle && bundle install")
      expect { ir.install_gems }.to hop
    end
  end

  describe "#validate" do
    it "runs the validate script" do
      expect(sshable).to receive(:_cmd).with("common/bin/validate")
      expect { ir.validate }.to exit({"msg" => "installed rhizome"})
    end
  end
end
