# frozen_string_literal: true

class Prog::SetupMinioNode < Prog::Base
  subject_is :minio_node

  def start
    bud Prog::PrepMinio
    bud Prog::ConfigureMinio
    hop :wait_prep
  end

  def wait_prep
    wait_buds_then_hop(:setup_users)
  end

  def setup_users
    bud Prog::SetupMinioUsers
    hop :wait_setup_users
  end

  def wait_setup_users
    wait_buds_then_hop(:start_node)
  end

  def start_node
    # gotta check if this fails when not started successfully
    minio_node.sshable.cmd("sudo systemctl start minio")
    pop "started minio node"
  end
end
