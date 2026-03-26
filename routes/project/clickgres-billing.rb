# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "clickgres-billing") do |r|
    r.get "postgres-resources" do
      # Project ownership enforced by parent route; no finer-grained RBAC needed for this machine-to-machine API.
      no_authorization_needed

      start_time, end_time = typecast_params.str(%w[start_time end_time])
      start_time = Validation.validate_rfc3339_datetime_str(start_time, "start_time")
      end_time = Validation.validate_rfc3339_datetime_str(end_time, "end_time")

      if end_time < start_time
        raise CloverError.new(400, "InvalidRequest", "end_time must be after start_time")
      end

      dataset = BillingRecord
        .where(project_id: @project.id)
        .where(Sequel.lit("jsonb_typeof(resource_tags) = 'object'"))
        .overlapping(start_time, end_time)

      # Filtering by chc_org_id scopes results to ClickGres-managed postgres resources.
      if (chc_org_id = typecast_params.str("chc_org_id"))
        dataset = dataset.with_tag("chc_org_id", chc_org_id)
      end

      dataset = dataset.distinct_by_resource

      {items: Serializers::BillingResource.serialize(dataset.all)}
    end
  end
end
