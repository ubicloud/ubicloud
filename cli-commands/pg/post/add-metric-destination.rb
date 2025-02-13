# frozen_string_literal: true

UbiRodish.on("pg").run_on("add-metric-destination") do
  options("ubi pg location/(pg-name|_pg-ubid) add-metric-destination username password url")

  args 3, invalid_args_message: "username, password, and url arguments are required"

  run do |username, password, url|
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
end
