# frozen_string_literal: true

module Ubicloud
  class AppProcess < Model
    set_prefix "ap"

    set_fragment "app"

    set_columns :id, :name, :group_name, :process_name, :location, :vm_size,
      :desired_count, :subnet, :load_balancer, :members,
      :health_count, :total_count, :health_label, :hostname,
      :deployment_managed, :umi_ref, :init_tags,
      :connected_subnets, :release_number, :processes,
      :push_results

    # Add existing VMs to the app process by name, or create a new VM
    # if no names are given.
    def add(vm_names: nil)
      params = vm_names ? {vm_names: vm_names} : {}
      merge_into_values(adapter.post(_path("/add"), **params))
    end

    # Detach a VM from the app process.
    def detach(vm_name:)
      merge_into_values(adapter.post(_path("/detach"), vm_name: vm_name))
    end

    # Remove (destroy) a VM.
    def remove(vm_name:)
      merge_into_values(adapter.post(_path("/remove"), vm_name: vm_name))
    end

    # Set image, init scripts, and/or VM size on the process type.
    def set(umi: nil, vm_size: nil, init: nil, from: nil, keep: nil)
      params = {}
      params[:umi] = umi if umi
      params[:vm_size] = vm_size if vm_size
      params[:init] = init if init
      params[:from] = from if from
      params[:keep] = keep if keep
      merge_into_values(adapter.post(_path("/set"), **params))
    end

    # Set desired VM count.
    def scale(count:)
      merge_into_values(adapter.post(_path("/scale"), count: count))
    end

    # Get release history for the app group.
    def releases
      adapter.get(_path("/releases"))
    end
  end
end
