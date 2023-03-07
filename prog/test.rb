# frozen_string_literal: true

# A no-operation prog for testing.
class Prog::Test < Prog::Base
  def start
  end

  def synchronized
    th = Thread.list.find { _1.name == "clover_test" }
    w = th[:clover_test_in]
    th.thread_variable_set(:clover_test_out, Thread.current)
    w.close
  end

  def wait_exit
    th = Thread.list.find { _1.name == "clover_test" }
    r = th[:clover_test_in]
    r.read
  end

  def hop_entry
    hop :hop_exit
  end

  def reaper
    reap
  end
end
