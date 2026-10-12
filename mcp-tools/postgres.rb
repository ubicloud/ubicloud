# frozen_string_literal: true

module UbiMcp
  module Tools
    class ListPostgres < Tool
      tool_name "list_postgres"
      description "List PostgreSQL databases in the project with summary fields such as state, live and target size, storage and version, HA type, replica flag and tags."
      input_schema(
        properties: {
          location: LOCATION_PROPERTY,
          tags: {type: "string", description: "Only databases with all of these key:value tags, comma separated; not combinable with location"},
          limit: LIMIT_PROPERTY,
          cursor: CURSOR_PROPERTY,
        },
        additionalProperties: false,
      )

      def self.run(adapter, location: nil, tags: nil, limit: 50, cursor: nil)
        tags = nil if tags && tags.strip.empty?
        raise Invalid, "tags cannot be combined with location" if location && tags

        page = paged(adapter, location_path(location, "postgres"), prefix: "pg", limit:, cursor:, tags:)
        page[:items].each { it.delete(:ca_certificates) }
        page
      end
    end

    class GetPostgres < Tool
      tool_name "get_postgres"
      description "Details of one PostgreSQL database, including its servers, read replicas, firewall rules, metric and log destinations and maintenance window. The point-in-time restore window runs from `earliest_restore_time` (null until a backup exists) to `latest_restore_time`; both are absent for read replicas and during a restore. `converged` is true when the database and all its servers are running and no resize, storage change, version upgrade, HA change or server replacement is pending; otherwise `pending` lists what is not settled. `converged` can be true before other changes, such as configuration or firewall changes, take effect, and a parameter that needs a restart takes effect only after the database restarts. `upgrade`, present during a version upgrade and after a failed one, gives its `status` (running or failed) and `stage`; a failed upgrade never converges on its own and the database stays on its old version, so stop polling. A read replica's pending changes wait for its `parent` (a /location/<location>/postgres/<name> path) to have none and to have a backup, which can take hours after the parent's upgrade, so check the parent and stop if its upgrade failed."
      input_schema(
        properties: {
          ref: ref_property("pg"),
        },
        required: ["ref"],
        additionalProperties: false,
      )

      def self.run(adapter, ref:)
        path = resource_path(adapter, "postgres", ref, prefix: "pg")
        info = adapter.get(path).except(:password, :connection_string, :private_connection_string, :ca_certificates)
        needs_convergence = info.delete(:needs_convergence)
        servers = adapter.get("#{path}/servers")[:items]
        if info[:version] != info[:target_version]
          begin
            upgrade = adapter.get("#{path}/upgrade")
          rescue Ubicloud::Error => e
            raise unless e.code == 400
          end
        end

        pending = []
        pending << "vm_size: #{info[:vm_size]} -> #{info[:target_vm_size]}" unless info[:fallback_active] || info[:vm_size] == info[:target_vm_size]
        pending << "storage_size_gib: #{info[:storage_size_gib]} -> #{info[:target_storage_size_gib]}" unless info[:storage_size_gib] == info[:target_storage_size_gib]
        pending << "version: #{info[:version]} -> #{info[:target_version]}" unless info[:version] == info[:target_version]
        pending << "servers: #{servers.size} of #{info[:target_server_count]}" unless servers.size == info[:target_server_count]
        pending << "servers: replacement pending" if needs_convergence && pending.empty?
        pending << "state: #{info[:state]}" unless info[:state] == "running"
        servers.each { pending << "server #{it[:id]}: #{it[:state]}" unless it[:state] == "running" }

        info[:read_replicas].map! { it.slice(:id, :name, :location, :state) }
        info[:log_destinations].map! { it.slice(:name, :type) }
        info[:metric_destinations].map! { {id: it[:id], host: URI.parse(it[:url]).host} }
        info[:servers] = servers
        info[:upgrade] = {status: upgrade[:upgrade_status], stage: upgrade[:upgrade_stage]} if upgrade
        info[:converged] = pending.empty?
        info[:pending] = pending
        info
      end
    end

    class GetPostgresConfig < Tool
      tool_name "get_postgres_config"
      description "Configuration of a PostgreSQL database: `pg_config` and `pgbouncer_config` are the user's PostgreSQL and PgBouncer overrides, and `default_pg_config` is the PostgreSQL configuration Ubicloud sets, which the overrides take precedence over. The PgBouncer settings Ubicloud sets itself, such as its pool mode and connection limits, are not returned."
      input_schema(
        properties: {
          ref: ref_property("pg"),
          keys: {type: "array", items: {type: "string"}, description: "Return only these parameters from each of the three, e.g. [\"shared_buffers\",\"max_connections\"]"},
          include_defaults: {type: "boolean", description: "Also return default_pg_config, which is large unless keys narrows it"},
        },
        required: ["ref"],
        additionalProperties: false,
      )

      def self.run(adapter, ref:, keys: nil, include_defaults: false)
        config = adapter.get("#{resource_path(adapter, "postgres", ref, prefix: "pg")}/config")
        config.delete(:default_pg_config) unless keys || include_defaults
        return config unless keys

        keys = keys.map(&:to_sym)
        config.transform_values! { it.slice(*keys) }
      end
    end

    class ListPostgresBackups < Tool
      tool_name "list_postgres_backups"
      description "Backup inventory of a PostgreSQL database: the `count`, the `oldest` backup and the newest `limit` backups (`newest`, newest first), each with a `key` and a `last_modified` time. The restore window is in `get_postgres`."
      input_schema(
        properties: {
          ref: ref_property("pg"),
          limit: {type: "integer", minimum: 1, maximum: 100, description: "How many of the newest backups to return (default 5)"},
        },
        required: ["ref"],
        additionalProperties: false,
      )

      def self.run(adapter, ref:, limit: 5)
        backups = adapter.get("#{resource_path(adapter, "postgres", ref, prefix: "pg")}/backup")
        items = backups[:items].sort_by { it[:last_modified] }
        {count: backups[:count], oldest: items.first, newest: items.last(limit).reverse}
      end
    end

    class GetPostgresOptions < Tool
      tool_name "get_postgres_options"
      description "What PostgreSQL databases this project can create. `metadata` lists the locations (keyed by internal name, with their display names), flavors, families, sizes (vCPU, memory) and HA types, but no versions or storage sizes. With `location`, `option_tree` adds each flavor offered there with its versions and valid family, size, storage size and HA type combinations. Use it before proposing a size or saying where something can be created."
      input_schema(
        properties: {
          location: {type: "string", description: "Display name of a location that offers PostgreSQL"},
        },
        additionalProperties: false,
      )

      def self.run(adapter, location: nil)
        capabilities = adapter.get("postgres/capabilities")
        metadata = capabilities[:metadata]
        return {metadata:} unless location

        name, = metadata[:location].find { |_, v| v[:display_name] == location }
        unless name
          offered = metadata[:location].map { |_, v| v[:display_name] }.join(", ")
          raise Invalid, "location must be the display name of a location that offers PostgreSQL for this project: #{offered}"
        end

        flavors = capabilities[:option_tree][:flavor].select { |_, tree| tree[:location].key?(name) }
        option_tree = flavors.transform_values { {version: it[:version], location: {location => it[:location][name]}} }
        {metadata:, option_tree:}
      end
    end
  end
end
