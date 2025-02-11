# frozen_string_literal: true

UbiRodish.on("pg").run_is("add-metric-destination", args: 3, invalid_args_message: "username, password, and url are required") do |username, password, url|
  params = {
    "username" => username,
    "password" => password,
    "url" => url
  }
  post(project_path("location/#{@location}/postgres/#{@name}/metric-destination"), params) do |data|
    body = []
    body << "Metric destination added to PostgreSQL database.\n"
    body << "Current metric destinations:\n"
    data["metric_destinations"].each_with_index do |md, i|
      body << "  " << (i + 1).to_s << ": " << md["id"] << "  " << md["username"].to_s << "  " << md["url"] << "\n"
    end
    body
  end
end
