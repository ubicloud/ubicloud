# frozen_string_literal: true

# The gateways' own reporting channel, as opposed to the per-ember calls
# next door in routes/internal/ember.rb. It is a file of its own because
# route files are autoloaded by branch name: a branch declared inside another
# file does not exist until something has hit that file's URL.
class Clover
  hash_branch(:internal_prefix, "gateway") do |r|
    r.post "activity" do
      body = r.body.read
      next 400 if body.nil? || body.empty?

      begin
        parsed = JSON.parse(body)
      rescue JSON::ParserError
        next 400
      end

      # A bare array is the older shape, from a gateway that has not been
      # upgraded yet; it reports activity but asks nothing back.
      reports, cached = case parsed
      when Array then [parsed, []]
      when Hash then [parsed["reports"], parsed["cached"]]
      end
      next 400 unless reports.is_a?(Array)

      apply_activity_reports(reports)
      {"invalidate" => stale_routes(cached)}
    end
  end
end
