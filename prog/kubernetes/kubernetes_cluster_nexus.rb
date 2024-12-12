# frozen_string_literal: true

class Prog::Kubernetes::KubernetesClusterNexus < Prog::Base
  subject_is :kubernetes_cluster
  semaphore :destroy

  def self.assemble(name:, kubernetes_version:, subnet:, project_id:, location:, replica: 3)
    DB.transaction do
      unless (project = Project[project_id])
        fail "No existing project"
      end

      kc = KubernetesCluster.create_with_id(
        name: name,
        kubernetes_version: kubernetes_version,
        replica: replica,
        subnet: subnet,
        location: location
      )

      kc.associate_with_project(project)
      Strand.create(prog: "Kubernetes::KubernetesClusterNexus", label: "start") { _1.id = kc.id }
    end
  end

  label def start
    when_destroy_set? do
      hop_destroy
    end

    nap 30
  end

  label def wait
    hop_start
  end

  label def destroy
    decr_destory

    pop "kubernetes cluster is deleted"
  end
end
