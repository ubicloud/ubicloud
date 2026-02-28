# frozen_string_literal: true

UbiCli.on("app").run_on("releases") do
  desc "Show release history"

  run do
    result = sdk_object.releases
    items = result[:items] || []

    if items.empty?
      response(["No releases yet.\n"])
    else
      body = ["\n"]

      # Compute column widths
      max_vnum = items.map { |r| "v#{r[:release_number]}".length }.max

      items.each do |rel|
        vnum = "v#{rel[:release_number]}"
        date = begin
          t = Time.parse(rel[:created_at])
          t.strftime("%b %d")
        rescue
          ""
        end

        process = rel[:process_name] || ""
        umi_ref = rel[:umi_ref] || ""
        init_tags = rel[:init_tags] || []
        init_str = init_tags.map { |t| t[:ref] }.join("  ")

        parts = [umi_ref, init_str].reject(&:empty?).join("  ")

        line = "  #{vnum.rjust(max_vnum)}   #{date}  #{process.ljust(8)} #{parts}"
        body << line.rstrip << "\n"
      end

      response(body)
    end
  end
end
