# frozen_string_literal: true

class Clover
  hash_branch("object-storage") do |r|
    r.get true do
      view content: render("components/page_header", locals: {title: "This service is under development"})
    end
  end
end
