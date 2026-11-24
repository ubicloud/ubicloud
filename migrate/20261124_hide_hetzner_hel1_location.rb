# frozen_string_literal: true

Sequel.migration do
  hel1 = "1f214853-0bc4-8020-b910-dffb867ef44f"

  up { from(:location).where(id: hel1).update(visible: false) }
  down { from(:location).where(id: hel1).update(visible: true) }
end
