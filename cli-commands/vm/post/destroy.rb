# frozen_string_literal: true

UbiRodish.on("vm").run_is("destroy") do
  delete(project_path("location/#{@location}/vm/#{@name}")) do |_, res|
    ["VM, if it exists, is now scheduled for destruction"]
  end
end
