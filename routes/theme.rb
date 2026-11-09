# frozen_string_literal: true

class Clover
  hash_branch("theme") do |r|
    r.web do
      r.post %w[light dark system] do |theme|
        no_authorization_needed
        no_audit_log

        if theme == "system"
          session.delete("theme")
        else
          session["theme"] = theme
        end

        r.redirect env["HTTP_REFERER"] || "/"
      end
    end
  end
end
