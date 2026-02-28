# frozen_string_literal: true

Sequel.migration do
  up do
    %w[create delete edit view].each do |action|
      name = "InitScriptTag:#{action}"
      next if from(:action_type).where(name: name).any?
      from(:action_type).insert(id: Sequel.lit("gen_random_uuid()"), name: name)
    end
  end

  down do
    from(:action_type).where(Sequel.like(:name, "InitScriptTag:%")).delete
  end
end
