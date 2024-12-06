# frozen_string_literal: true

class Prog::Kubernetes::KubernetesNodepoolNexus < Prog::Base
  subject_is :kubernetes_nodepool

  def self.assemble
  end

  label def start
    nap 30
  end

  label def wait
  end

  label def destroy
    pop "done"
  end
end
