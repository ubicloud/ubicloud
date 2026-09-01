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
    project: {
      after_create: ->(ctx, row) { ctx.tf_grant_pat!(row) },
      gone: ->(_, row) { expect(row.nil? || !row.visible).to be true },
    },
  }.freeze
end
