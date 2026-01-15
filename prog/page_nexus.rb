# frozen_string_literal: true

class Prog::PageNexus < Prog::Base
  subject_is :page

  def self.assemble(summary, tag_parts, related_resources, severity: "error", extra_data: {})
    DB.transaction do
      details = extra_data.merge({"related_resources" => Array(related_resources)})
      tag = Page.generate_tag(tag_parts)
      page = Page.new(summary:, details:, tag:, severity:)
      page.skip_auto_validations(:unique) do
        page.insert_conflict(
          target: :tag,
          conflict_where: {resolved_at: nil},
          update: {summary: Sequel[:excluded][:summary], details: Sequel[:excluded][:details], severity: Sequel[:excluded][:severity]}
        ).save_changes
      end

      Strand.new(prog: "PageNexus", label: "start") { it.id = page.id }
        .insert_conflict(target: :id).save_changes
    end
  end

  label def start
    page.trigger
    hop_wait
  end

  label def wait
    when_resolve_set? do
      page.resolve
      page.destroy
      pop "page is resolved"
    end

    nap 6 * 60 * 60
  end
end
