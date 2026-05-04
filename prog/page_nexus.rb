# frozen_string_literal: true

class Prog::PageNexus < Prog::Base
  subject_is :page

  def self.assemble(summary, tag_parts, related_resources, severity: "error", extra_data: {})
    DB.transaction do
      related_resources = Array(related_resources)
      details = extra_data.merge({"related_resources" => related_resources})
      tag = Page.generate_tag(tag_parts)

      if (existing_page = Page.first(tag:)) && Page.severity_order(severity) > Page.severity_order(existing_page.severity)
        existing_page.incr_retrigger
      end

      new_page_id = Page.generate_uuid
      page_id = Page.dataset
        .insert_conflict(
          target: :tag,
          conflict_where: {resolved_at: nil},
          update: {summary: Sequel[:excluded][:summary], details: Sequel[:excluded][:details], severity: Sequel[:excluded][:severity]},
        )
        .insert(id: new_page_id, summary:, details: Sequel.pg_jsonb(details), tag:, severity:)

      # If the returned page id matches the randomly generated one, there was a new page inserted.
      # If a new page was not inserted, then nothing needs to be done.
      if page_id == new_page_id
        uuid_map = {}
        related_resources.each { uuid_map[UBID.to_uuid(it)] = nil }
        UBID.resolve_map(uuid_map) do |ds|
          if (assocs = Page::EAGER_ROOT_RESOURCES[ds.model.name])
            ds = ds.eager(assocs)
          end
          ds
        end
        group_ids = uuid_map.values.compact.flat_map { Page.root_resources(it) }
        frame = {}

        # Check if the new page is related to an existing recent page that did not suppress triggers.
        # If so, suppress triggers for the current page.
        duplicate = !DB[:page_root_resource]
          .where(root_resource_id: group_ids, duplicate: false) { at > Time.now - 15 * 60 }
          .empty?

        frame["suppress_triggers"] = true if duplicate

        # Associate the page with the related resources, along with
        # whether the current page was considered a duplicate (duplicate implies trigger suppression).
        DB[:page_root_resource].import([:page_id, :root_resource_id, :duplicate], group_ids.map { [page_id, it, duplicate] })

        Strand.create_with_id(page_id, prog: "PageNexus", label: "start", stack: [frame])
      end
    end
  end

  label def start
    page.trigger unless frame["suppress_triggers"]
    hop_wait
  end

  label def wait
    when_retrigger_set? do
      # If retriggering due to an escalation, always trigger,
      # even if triggers were originally suppressed.
      update_stack("suppress_triggers" => false)
      page.trigger
      decr_retrigger
    end

    when_resolve_set? do
      page.resolve unless frame["suppress_triggers"]
      page.destroy
      pop "page is resolved"
    end

    nap 6 * 60 * 60
  end
end
