# frozen_string_literal: true

module Ubicloud
  class KubernetesCluster < Model
    set_prefix "kc"

    set_fragment "kubernetes-cluster"

    set_columns :id, :name, :state, :location
  end
end
