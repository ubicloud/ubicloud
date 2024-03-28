# frozen_string_literal: true

class Prog::PageNexus < Prog::Base
  subject_is :page
  semaphore :resolve

  def self.assemble(summary, related_resources, *tag_parts)
    DB.transaction do
      pg = Page.from_tag_parts(tag_parts)
      unless pg
        pg = Page.create_with_id(summary: summary, details: {"related_resources" => Array(related_resources)}, tag: Page.generate_tag(tag_parts))
        Strand.create(prog: "PageNexus", label: "start") { _1.id = pg.id }
      end
    end
  end

  label def start
    page.trigger
    hop_wait
  end

  label def wait
    when_resolve_set? do
      page.resolve
      pop "page is resolved"
    end

    nap 30
  end
end
