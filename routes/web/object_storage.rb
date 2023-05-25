# frozen_string_literal: true

class CloverWeb
  hash_branch("object-storage") do |r|
    r.get true do
      @page_title = "Object Storage"
      view content: render("components/page_header", locals: {title: "This service is under development"})
    end
  end
end
