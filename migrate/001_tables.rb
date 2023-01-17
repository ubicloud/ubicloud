Sequel.migration do
  change do
    create_table(:model1s) do
      primary_key :id
    end
  end
end
