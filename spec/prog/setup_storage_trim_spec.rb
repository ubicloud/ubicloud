# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupStorageTrim do
  subject(:st) {
    described_class.new(Strand.create_with_id(sshable, prog: "SetupStorageTrim", label: "start"))
  }

  let(:sshable) { Sshable.create }

  describe "#start" do
    it "makes the stock fstrim timer run every three hours on extents of 2 MiB and more, restarts it, and pops" do
      expect(st.sshable).to receive(:_cmd).with("sudo mkdir -p /etc/systemd/system/fstrim.timer.d /etc/systemd/system/fstrim.service.d")
      expect(st.sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/fstrim.timer.d/schedule.conf > /dev/null", stdin: "[Timer]\nOnCalendar=\nOnCalendar=*-*-* 00/3:00:00\nAccuracySec=1min\nRandomizedDelaySec=10min\n")
      expect(st.sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/fstrim.service.d/minimum.conf > /dev/null", stdin: "[Service]\nExecStart=\nExecStart=/sbin/fstrim --all --verbose --quiet-unsupported --minimum 2M\n")
      expect(st.sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(st.sshable).to receive(:_cmd).with("sudo systemctl enable fstrim.timer")
      expect(st.sshable).to receive(:_cmd).with("sudo systemctl restart fstrim.timer")
      expect { st.start }.to exit({"msg" => "fstrim timer configured"})
    end
  end
end
