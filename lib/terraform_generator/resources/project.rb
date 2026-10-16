# frozen_string_literal: true

TerraformGenerator.resource :project do
  details_sample "/project/x"
  create_sample "/project"
  key_attrs project_id: :id

  # Classification derives from the spec's readOnly; this line supplies
  # the injected key's only description.
  attr :id, description: "ID of the project"
  # Demand the name at plan time; derivation would mark it
  # computed_optional and defer a missing name to apply.
  attr :name, classification: :required, kinds: [:resource]
end
