# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::CheckForNewHostKeys do
  subject(:prog) { described_class.new(Strand.new(prog: "CheckForNewHostKeys", label: "start", stack: [{}])) }

  describe "#start" do
    it "records the run start and resets the sshable position, then hops to check" do
      expect { prog.start }.to hop("check")
      expect(prog.last_run_start).to be_within(5).of(Time.now.to_i)
      expect(prog.last_sshable_id).to eq "00000000-0000-0000-0000-000000000000"
    end
  end

  describe "#check" do
    it "checks each sshable with host keys in id order, napping between each, then hops to wait" do
      ids = Array.new(3) { Sshable.generate_uuid }.sort
      ids.each_with_index.reverse_each do |id, i|
        Sshable.create_with_id(id, host: "host#{i}", host_keys: (i == 1) ? nil : ["ssh-ed25519 AAAA#{i}"])
      end
      checked = []
      allow(prog).to receive(:next_sshable).and_wrap_original do |m|
        m.call&.tap do |sshable|
          expect(sshable).to receive(:check_for_new_host_keys) { checked << sshable.id }
        end
      end
      prog.last_sshable_id = "00000000-0000-0000-0000-000000000000"

      expect { prog.check }.to nap(10 * 60)
      expect(checked).to eq [ids[0]]
      expect(prog.last_sshable_id).to eq ids[0]

      # Sshable without host keys is skipped
      expect { prog.check }.to nap(10 * 60)
      expect(checked).to eq [ids[0], ids[2]]
      expect(prog.last_sshable_id).to eq ids[2]

      expect { prog.check }.to hop("wait")
      expect(checked).to eq [ids[0], ids[2]]
    end

    [Errno::ECONNREFUSED.new, Net::SSH::AuthenticationFailed.new("testuser")].each do |error|
      it "logs #{error.class} errors and moves past the sshable" do
        sshable = Sshable.create(host: "host", host_keys: ["ssh-ed25519 AAAA"])
        expect(prog).to receive(:next_sshable).and_return(sshable)
        expect(sshable).to receive(:check_for_new_host_keys).and_raise(error)
        expect(Clog).to receive(:emit).with("unable to check for new host keys", hash_including(
          sshable_check_for_new_host_keys_failure: {ubid: sshable.ubid},
          exception: hash_including(class: error.class.to_s),
        )).and_call_original

        expect { prog.check }.to nap(10 * 60)
        expect(prog.last_sshable_id).to eq sshable.id
      end
    end

    it "does not rescue other errors" do
      sshable = Sshable.create(host: "host", host_keys: ["ssh-ed25519 AAAA"])
      expect(prog).to receive(:next_sshable).and_return(sshable)
      expect(sshable).to receive(:check_for_new_host_keys).and_raise(RuntimeError, "unexpected")
      expect(Clog).not_to receive(:emit)

      expect { prog.check }.to raise_error(RuntimeError, "unexpected")
    end
  end

  describe "#wait" do
    it "naps until the next run should start" do
      prog.last_run_start = Time.now.to_i - 24 * 60 * 60
      expected = 29 * 24 * 60 * 60 + 60
      expect { prog.wait }.to nap((expected - 5)..(expected + 5))
    end

    it "hops to start when it is time for the next run" do
      prog.last_run_start = Time.now.to_i - 30 * 24 * 60 * 60 - 1
      expect { prog.wait }.to hop("start")
    end
  end
end
