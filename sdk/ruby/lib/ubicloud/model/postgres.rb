# frozen_string_literal: true

module Ubicloud
  class Postgres < Model
    set_prefix "pg"

    set_fragment "postgres"

    set_columns :id, :name, :state, :location, :vm_size, :storage_size_gib, :version, :ha_type, :flavor, :ca_certificates, :connection_string, :primary, :firewall_rules, :metric_destinations

    set_create_param_defaults do |params|
      params[:size] ||= "standard-2"
    end

    def restart
      merge_into_values(adapter.post(path("/restart")))
    end

    def add_firewall_rule(cidr)
      adapter.post(path("/firewall-rule"), cidr:)
    end

    def delete_firewall_rule(rule_id)
      raise Error, "invalid rule id format" if rule_id.include?("/")
      adapter.delete(path("/firewall-rule/#{rule_id}"))
    end

    def add_metric_destination(username, password, url)
      adapter.post(path("/metric-destination"), username:, password:, url:)
    end

    def delete_metric_destination(md_id)
      raise Error, "invalid metric destination id format" if md_id.include?("/")
      adapter.delete(path("/metric-destination/#{md_id}"))
    end

    def reset_superuser_password(password)
      merge_into_values(adapter.post(path("/reset-superuser-password"), password:))
    end

    def restore(name, restore_target)
      Postgres.new(adapter, adapter.post(path("/restore"), name:, restore_target:))
    end
  end
end
