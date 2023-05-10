# frozen_string_literal: true

class Prog::SetupMinioUsers < Prog::Base
  subject_is :sshable

  def start
    sshable.cmd(<<SH)
set -euo pipefail
sudo groupadd -r minio-user
sudo useradd -M -r -g minio-user minio-user
sudo chown -R minio-user:minio-user /storage
sudo chown -R minio-user:minio-user /etc/default/minio
SH

    pop "minio users setup is done"
  end
end
