# frozen_string_literal: true

module Ubicloud
  class Postgres < Model
    set_prefix "pg"

    set_fragment "postgres"

    set_columns :id, :name, :state, :location, :vm_size, :storage_size_gib, :version, :ha_type, :flavor, :ca_certificates, :connection_string, :primary, :firewall_rules, :metric_destinations

    set_create_param_defaults do |params|
      params[:size] ||= "standard-2"
    end

    # Schedule a restart of the PostgreSQL server. Returns self.
    def restart
      merge_into_values(adapter.post(_path("/restart")))
    end

    # Allow the given cidr (ip address range) access to the PostgreSQL database port (5432)
    # for this database. Returns a hash for the firewall rule.
    def add_firewall_rule(cidr)
      rule = adapter.post(_path("/firewall-rule"), cidr:)

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
