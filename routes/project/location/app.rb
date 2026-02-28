# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "app") do |r|
    r.get api? do
      app_process_list
    end

    r.on APP_PROCESS_NAME_OR_UBID do |ap_name, ap_id|
      if ap_name
        r.post api? do
          check_visible_location
          app_process_post(ap_name)
        end

        # Look up by display_name (group_name || '-' || name)
        filter = {Sequel.join([Sequel[:app_process][:group_name], "-", Sequel[:app_process][:name]]) => ap_name}
      else
        filter = {Sequel[:app_process][:id] => ap_id}
      end

      ap = @project.app_processes_dataset.where(location_id: @location.id).first(filter)
      check_found_object(ap)

      r.post "add" do
        app_process_add(ap)
      end

      r.post "detach" do
        app_process_detach(ap)
      end

      r.post "remove" do
        app_process_remove(ap)
      end

      r.post "set" do
        app_process_set(ap)
      end

      r.post "scale" do
        app_process_scale(ap)
      end

      r.get "releases" do
        app_process_releases(ap)
      end

      r.get true do
        authorize("AppProcess:view", ap)
        if api?
          Serializers::AppProcess.serialize(ap, {detailed: true, group_status: true})
        else
          r.redirect ap, "/overview"
        end
      end

      r.delete true do
        authorize("AppProcess:delete", ap)
        audit_log(ap, "destroy")
        DB.transaction do
          ap.destroy
        end

        if web?
          flash["notice"] = "App process deleted."
          r.redirect @project, "/app"
        else
          204
        end
      end
    end
  end
end
