# frozen_string_literal: true

# A no-operation prog for testing.
class Prog::Test2 < Prog::Base
  semaphore :destroy

  def before_destroy
    Clog.emit("before destroy called")
  end

  label def pusher1
    push Prog::Test, {test_level: "2"}, :pusher2
  end

  def transaction_around_run?
    !strand.label.start_with?("deferred_transaction_")
  end

  label def deferred_transaction_napper
    nap 1
  end
end
