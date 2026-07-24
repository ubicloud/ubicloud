# frozen_string_literal: true

# Extension state accessors shared across a resource's cluster. Included into
# PostgresResource; relies on `read_replica?`, `parent`, `servers`, and
# `read_replicas` from the host class.
module PostgresExtensionOrchestrationMethods
  def effective_desired_extensions
    read_replica? ? parent.desired_extensions : desired_extensions
  end

  def effective_extension_config
    read_replica? ? parent.extension_config : extension_config
  end

  def cluster_servers
    servers + read_replicas.flat_map(&:servers)
  end
end
