# frozen_string_literal: true

# A no-operation prog for testing.
class Prog::Test2 < Prog::Base
  label def pusher1
    push Prog::Test, {test_level: "2"}, :pusher2
  end
end
