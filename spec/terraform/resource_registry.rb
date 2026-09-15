# frozen_string_literal: true

# Everything derivable derives. The model class
# comes from the resource name by convention (one exception below);
# the finder defaults to first-by-name; the fixture and address derive
# unless a curated body exists. What remains per resource is exactly
# the async-doctrine hooks - the knowledge behind the API boundary
# that reflection cannot see and lambdas must carry (which is also why
# this stays Ruby). A conforming resource needs NO entry at all.
module TerraformHarness
  MODEL_EXCEPTIONS = {postgres: "PostgresResource"}.freeze

  def self.model_for(name)
    Object.const_get(MODEL_EXCEPTIONS[name] || name.to_s.split("_").map(&:capitalize).join)
  end

  RESOURCE_REGISTRY = {
    # Nested under a fixed parent: the fixture creates firewall
    # rule-host, lookups and gate paths route through it, and the
    # rule's own key is its server-assigned id.
    firewall_rule: {
      fixture: "firewall_rule.tf.erb", address: "ubicloud_firewall_rule.r",
      name_fixed: "rule-host",
      find: ->(_) { Firewall.first(name: "rule-host")&.firewall_rules_dataset&.first },
      create_path: %r{/firewall/rule-host/firewall-rule\z},
      delete_path: ->(row) { %r{/firewall-rule/#{row.ubid}\z} },
    },
    postgres: {
      fixture: "postgres_basic.tf.erb", address: "ubicloud_postgres.db",
      # Creation consults Config.postgres_service_project_id; stub it
      # with a real project.
      prepare: ->(ctx) do
        service_project = Project.create(name: "default")
        ctx.instance_exec { allow(Config).to receive(:postgres_service_project_id).and_return(service_project.id) }
      end,
      converge_create: ->(ctx, row) { ctx.make_pg_running!(row) },
      converge_delete: ->(_, row) do
        100.times {
          break if SemSnap.new(row.id).set?("destroy")
          sleep 0.05
        }
        raise "destroy semaphore never set" unless SemSnap.new(row.id).set?("destroy")
        row.destroy
      end,
    },
    private_subnet: {
      gone: ->(_, row) { expect(row.nil? || SemSnap.new(row.id).set?("destroy")).to be true },
    },
    project: {
      after_create: ->(ctx, row) { ctx.tf_grant_pat!(row) },
      gone: ->(_, row) { expect(row.nil? || !row.visible).to be true },
    },
    vm: {
      fixture: "vm_basic.tf.erb", address: "ubicloud_vm.vm",
      gone: ->(_, row) { expect(SemSnap.new(row.id).set?("destroy")).to be true },
    },
  }.freeze
end
