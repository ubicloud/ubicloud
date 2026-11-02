# frozen_string_literal: true

class Serializers::KubernetesCluster < Serializers::Base
  def self.serialize_internal(kc, options = {})
    state = kc.display_state
    base = {
      id: kc.ubid,
      name: kc.name,
      location: kc.location.display_name,
      state:,
      display_state: state,
      cp_node_count: kc.cp_node_count,
      node_size: kc.target_node_size,
      version: kc.version,
      services_load_balancer_url: kc.services_lb&.hostname,
    }
    if options[:detailed]
      base[:cp_vms] = Serializers::Vm.serialize(kc.cp_vms_dataset.all)
      base[:nodepools] = Serializers::KubernetesNodepool.serialize(kc.nodepools(eager: [:strand, :semaphores, {vms: Serializers::KubernetesNodepool::VMS_EAGER}], reload: true))
    end
    base
  end
end
