# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "init-script-tag") do |r|
    r.get true do
      authorize("InitScriptTag:view", @project.id)

      tags = @project.init_script_tags_dataset.order(Sequel.asc(:name), Sequel.desc(:version)).all

      if api?
        {items: tags.map { |t|
          {
            id: t.ubid,
            name: t.name,
            version: t.version,
            size: t.init_script.bytesize,
            created_at: t.created_at.strftime("%b %-d")
          }
        }}
      else
        r.redirect @project, "/init-script-tag"
      end
    end

    r.post true do
      authorize("InitScriptTag:create", @project.id)

      name = typecast_params.nonempty_str!("name")
      content = typecast_params.nonempty_str!("content")

      Validation.validate_name(name)

      if content.bytesize > 2000
        fail Validation::ValidationFailed.new("content" => "Init script must be 2000 bytes or less")
      end

      # Find latest version for this name
      latest = @project.init_script_tags_dataset
        .where(name: name)
        .order(Sequel.desc(:version))
        .first

      # If content matches the latest version, skip
      if latest && latest.init_script == content
        if api?
          return {
            id: latest.ubid,
            name: latest.name,
            version: latest.version,
            size: latest.init_script.bytesize,
            created_at: latest.created_at.strftime("%b %-d"),
            unchanged: true
          }
        end
      end

      new_version = latest ? latest.version + 1 : 1

      tag = InitScriptTag.create(
        project_id: @project.id,
        name: name,
        version: new_version,
        init_script: content
      )

      if api?
        {
          id: tag.ubid,
          name: tag.name,
          version: tag.version,
          size: tag.init_script.bytesize,
          created_at: tag.created_at.strftime("%b %-d")
        }
      else
        flash["notice"] = "#{tag.ref} pushed"
        r.redirect @project, "/init-script-tag"
      end
    end

    r.on String do |ref|
      # ref can be "name@version" or a UBID
      tag = if ref.include?("@")
        tag_name, version_str = ref.split("@", 2)
        version = Integer(version_str, exception: false)
        version && @project.init_script_tags_dataset.first(name: tag_name, version: version)
      else
        uuid = UBID.to_uuid(ref)
        uuid && @project.init_script_tags_dataset.with_pk(uuid)
      end

      check_found_object(tag)
      authorize("InitScriptTag:view", tag)

      r.get true do
        if api?
          {
            id: tag.ubid,
            name: tag.name,
            version: tag.version,
            size: tag.init_script.bytesize,
            created_at: tag.created_at.strftime("%b %-d"),
            content: tag.init_script
          }
        else
          r.redirect @project, "/init-script-tag"
        end
      end
    end
  end
end
