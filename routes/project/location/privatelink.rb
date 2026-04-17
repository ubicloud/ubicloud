# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "privatelink") do |r|
    r.on :ubid_uuid do |pl_id|
      pl = @pl = PrivatelinkAwsResource[pl_id]
      check_found_object(pl)

      # Scope to current project via the owning subnet
      check_found_object(nil) unless pl.private_subnet.project_id == @project.id

      r.get true do
        authorize("PrivateSubnet:view", pl.private_subnet)
        if api?
          Serializers::PrivatelinkAws.serialize(pl, {detailed: true})
        else
          @page_title = "AWS PrivateLink"
          view("privatelink/show")
        end
      end

      r.delete true do
        authorize("PrivateSubnet:edit", pl.private_subnet)
        DB.transaction do
          pl.incr_destroy
          audit_log(pl, "destroy")
        end

        if web?
          flash["notice"] = "PrivateLink endpoint scheduled for deletion."
          r.redirect pl.private_subnet, "/networking"
        else
          204
        end
      end
    end
  end
end
