# frozen_string_literal: true

module Ubicloud
  class Postgres < Model
    set_prefix "pg"

    set_fragment "postgres"

    set_columns :id, :name, :state, :location, :vm_size, :storage_size_gib, :version, :ha_type, :flavor, :ca_certificates, :connection_string, :primary, :firewall_rules, :metric_destinations, :tags, :maintenance_window_start_at, :read_replica, :parent, :read_replicas

    set_create_param_defaults do |params|
      params[:size] ||= "standard-2"
      if params[:tags]
        params[:tags] = params[:tags].map { |key, value| {key:, value:} }
      end
    end

    alias_method :_tags, :tags
    private :_tags
    # Return tags as a single hash instead of array of hashes with key and value keys.
    def tags
      _tags.to_h { it.values_at(:key, :value) }
    end

    # Schedule a restart of the PostgreSQL server. Returns self.
    def restart
      merge_into_values(adapter.post(_path("/restart")))
    end

    # Allow the given cidr (ip address range) access to the PostgreSQL database port (5432)
    # for this database. Returns a hash for the firewall rule.
    def add_firewall_rule(cidr, description: nil)
      rule = adapter.post(_path("/firewall-rule"), cidr:, description:)

      self[:firewall_rules]&.<<(rule)

      rule
    end

    # Delete the firewall rule with the given id.  Returns nil.
    def delete_firewall_rule(rule_id)
      check_no_slash(rule_id, "invalid rule id format")
      adapter.delete(_path("/firewall-rule/#{rule_id}"))

      self[:firewall_rules]&.delete_if { it[:id] == rule_id }

      nil
    end

    # Modify the firewall rule with the given id.  Returns the updated rule.
    def modify_firewall_rule(rule_id, cidr: nil, description: nil)
      check_no_slash(rule_id, "invalid rule id format")
      rule = adapter.patch(_path("/firewall-rule/#{rule_id}"), cidr:, description:)

      self[:firewall_rules]&.each { it.replace(rule) if it[:id] == rule_id }

      rule
    end

    # Add a metric destination for this database with the given username, password,
    # and URL. Returns a hash for the metric destination.
    def add_metric_destination(username:, password:, url:)
      md = adapter.post(_path("/metric-destination"), username:, password:, url:)

      self[:metric_destinations]&.<<(md)

      md
    end

    # Delete the metric destination with the given id.  Returns nil.
    def delete_metric_destination(md_id)
      check_no_slash(md_id, "invalid metric destination id format")
      adapter.delete(_path("/metric-destination/#{md_id}"))

      self[:metric_destinations]&.delete_if { it[:id] == md_id }

      nil
    end

    # Modify attributes of the database.
    def modify(ha_type: nil, size: nil, storage_size: nil, tags: nil)
      if tags
        tags = tags.map { |key, value| {key:, value:} }
      end
      params = {ha_type:, size:, storage_size:, tags:}
      params.compact!
      merge_into_values(adapter.patch(_path, **params))
    end

    # Return the configuration hash for the PostgreSQL database.
    def config
      adapter.get(_path("/config"))[:pg_config]
    end

    # Return the pgbouncer configuration hash for the PostgreSQL database.
    def pgbouncer_config
      adapter.get(_path("/config"))[:pgbouncer_config]
    end

    # Update configuration hash for the PostgreSQL database.
    def update_config(**values)
      adapter.patch(_path("/config"), pg_config: values)[:pg_config]
    end

    # Update configuration hash for the PostgreSQL database.
    def update_pgbouncer_config(**values)
      adapter.patch(_path("/config"), pgbouncer_config: values)[:pgbouncer_config]
    end

    # Create a read replica of this database, with the given name.
    def create_read_replica(name)
      Postgres.new(adapter, adapter.post(_path("/read-replica"), name:))
    end

    # Promote this database from a read replica to a primary.
    def promote_read_replica
      merge_into_values(adapter.post(_path("/promote")))
    end

    # Set the start hour (0-23) for the maintenance window, or nil
    # to unset the maintenance window.
    def set_maintenance_window(start_hour)
      params = {}
      if start_hour
        params[:maintenance_window_start_at] = start_hour
      end
      merge_into_values(adapter.post(_path("/set-maintenance-window"), params))
    end

    # Schedule a password reset for the database superuser (postgres) for the database.
    # Returns self.
    def reset_superuser_password(password)
      merge_into_values(adapter.post(_path("/reset-superuser-password"), password:))
    end

    # Schedule a restore of the database at the given restore_target time, to a new
    # database with the given name.  Returns a Postgres instance for the restored
    # database.
    def restore(name:, restore_target:)
      Postgres.new(adapter, adapter.post(_path("/restore"), name:, restore_target:))
    end
  end
end
