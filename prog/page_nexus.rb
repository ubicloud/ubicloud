# frozen_string_literal: true

class Prog::PageNexus < Prog::Base
  subject_is :page

  def self.assemble(summary, tag_parts, related_resources, severity: "error", extra_data: {})
    DB.transaction do
      return if Page.from_tag_parts(tag_parts)

      pg = Page.create_with_id(summary: summary, details: extra_data.merge({"related_resources" => Array(related_resources)}), tag: Page.generate_tag(tag_parts), severity: severity)
      Strand.create(prog: "PageNexus", label: "start") { it.id = pg.id }
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
