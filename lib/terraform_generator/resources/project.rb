# frozen_string_literal: true

# There is no resource, because the API does not create projects: a
# project access token is limited to its own project.
TerraformGenerator.resource :project do
  kinds :datasource
  details_sample "/project/x"
  key_attrs project_id: :id

  attr :id, description: "ID of the project"
end
