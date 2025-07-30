# frozen_string_literal: true

class Clover
  type_ds_perm_map = {
    "fw" => [:firewalls_dataset, "Firewall:view"],
    "kc" => [:kubernetes_clusters_dataset, "KubernetesCluster:view"],
    "1b" => [:load_balancers_dataset, "LoadBalancer:view"],
    "pg" => [:postgres_resources_dataset, "Postgres:view"],
    "ps" => [:private_subnets_dataset, "PrivateSubnet:view"],
    "vm" => [:vms_dataset, "Vm:view"]
  }.freeze
  type_ds_perm_map.each_value(&:freeze)

  hash_branch(:project_prefix, "object-info") do |r|
    r.get(api?, UbiCli::OBJECT_INFO_REGEXP) do |ubid, type|
      ds_method, perm = type_ds_perm_map[type]

      if (object = dataset_authorize(@project.send(ds_method), perm).first(id: UBID.to_uuid(ubid)))
        {
          "type" => object.class.table_name.to_s.tr("_", " "),
          "location" => object.display_location,
          "name" => object.name
        }
      end
    end
  end
end
