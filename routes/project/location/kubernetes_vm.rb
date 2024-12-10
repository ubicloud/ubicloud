# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "kubernetes-vm") do |r|
    r.get api? do
      kubernetes_vm_list
    end

    r.on NAME_OR_UBID do |kv_name, kv_id|
      if kv_name
        r.post true do
          post_kubernetes_vm(kv_name)
        end

        filter = {Sequel[:vm][:name] => kv_name}
        filter[:location] = @location
        vm = @project.vms_dataset.first(filter)
        filter = {Sequel[:kubernetes_vm][:vm_id] => vm.id}
      else
        filter = {Sequel[:kubernetes_vm][:id] => UBID.to_uuid(kv_id)}
      end
      kv = @project.kubernetes_vms_dataset.first(filter)

      request.get true do
        authorize("KubernetesVm:view", kv.id)
        @kv = Serializers::KubernetesVm.serialize(kv)
        if api?
          @kv
        else
          view "kubernetes/vm/show"
        end
      end
    end
  end
end
