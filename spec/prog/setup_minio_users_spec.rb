# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupMinioUsers do
  subject(:sm) { described_class.new(Strand.new(stack: [{sshable: "bogus"}])) }

  describe "#start" do
    it "runs the expected commands to setup minio-user" do
      sshable = instance_double(Sshable)
      expect(sshable).to receive(:cmd).with(<<SH)
set -euo pipefail
sudo groupadd -r minio-user
sudo useradd -M -r -g minio-user minio-user
sudo chown -R minio-user:minio-user /storage
sudo chown -R minio-user:minio-user /etc/default/minio
SH
      expect(sm).to receive(:sshable).and_return(sshable)
      expect(sm).to receive(:pop).with("minio users setup is done")
      sm.start
    end
  end
end
