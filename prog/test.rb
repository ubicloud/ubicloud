# frozen_string_literal: true

# A no-operation prog for testing.
class Prog::Test < Prog::Base
  def synchronized
    th = Thread.list.find { _1.name == "clover_test" }
    w = th[:clover_test_in]
    th.thread_variable_set(:clover_test_out, Thread.current)
    w.close
  end
end
