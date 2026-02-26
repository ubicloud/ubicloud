# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::InstallRhizome do
  subject(:ir) {
    described_class.new(Strand.create_with_id(sshable, prog: "InstallRhizome", label: "start", stack: [{"target_folder" => "host"}]))
  }

  let(:sshable) { Sshable.create }

  describe "#start" do
    it "writes tar" do
      expect(ir).to receive(:update_stack).with({"rhizome_digest" => instance_of(String)}).and_call_original
      expect(ir.sshable).to receive(:_cmd) do |*args, **kwargs|
        expect(args).to eq ["tar xf -"]

        expect(kwargs[:stdin].scan("Gemfile.lock").count).to be < 2

        # Take offset from
        # https://www.gnu.org/software/tar/manual/html_node/Standard.html
        expect(kwargs[:stdin][257..261]).to eq "ustar"
      end
      expect { ir.start }.to hop("install_gems")
    end

    it "writes tar including specs" do
      sshable2 = Sshable.create
      ir_spec = described_class.new(Strand.create_with_id(sshable2, prog: "InstallRhizome", label: "start", stack: [{"target_folder" => "host", "install_specs" => true}]))
      expect(ir_spec.sshable).to receive(:_cmd)
      expect { ir_spec.start }.to hop("install_gems")
    end
  end

  describe "#install_gems" do
    it "runs some commands and exits" do
      expect(ir.sshable).to receive(:_cmd).with("bundle config set --local path vendor/bundle && bundle install")
      expect { ir.install_gems }.to hop
    end
  end

  describe "#validate" do
    it "runs the validate script" do
      expect(ir).to receive(:frame).and_return({"target_folder" => "host", "rhizome_digest" => "abc"}).at_least(:once)
      expect(ir.sshable).to receive(:_cmd).with("common/bin/validate")
      expect { ir.validate }.to exit({"msg" => "installed rhizome"})

      expect(ir.sshable.rhizome_installation.folder).to eq("host")
      expect(ir.sshable.rhizome_installation.digest).to eq("abc")
      expect(ir.sshable.rhizome_installation.commit).to eq(Config.git_commit_hash)
      expect(ir.sshable.rhizome_installation.installed_at).to be_within(10).of(Time.now)
    end

    it "updates the rhizome installation" do
      RhizomeInstallation.dataset.insert(
        id: sshable.id,
        folder: "old_folder",
        commit: "old_commit",
        digest: "old_digest",
        installed_at: Time.now - 3600
      )
      expect(ir).to receive(:frame).and_return({"target_folder" => "host", "rhizome_digest" => "abc"}).at_least(:once)
      expect(ir.sshable).to receive(:_cmd).with("common/bin/validate")
      expect { ir.validate }.to exit({"msg" => "installed rhizome"})

      expect(ir.sshable.rhizome_installation.folder).to eq("host")
      expect(ir.sshable.rhizome_installation.digest).to eq("abc")
      expect(ir.sshable.rhizome_installation.commit).to eq(Config.git_commit_hash)
      expect(ir.sshable.rhizome_installation.installed_at).to be_within(10).of(Time.now)
    end
  end
end
