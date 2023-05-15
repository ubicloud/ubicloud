# frozen_string_literal: true

# A no-operation prog for testing.
class Prog::Test < Prog::Base
  def start
  end

  def pusher1
    pop 1 if retval
    push Prog::Test, {test_level: 2}, :pusher2
  end

  def pusher2
    pop frame[:test_level] if retval
    push Prog::Test, {test_level: 3}, :pusher3
  end

  def pusher3
    pop frame[:test_level]
  end

  def synchronized
    th = Thread.list.find { _1.name == "clover_test" }
    w = th[:clover_test_in]
    th.thread_variable_set(:clover_test_out, Thread.current)
    w.close
    pop "done"
  end

  def wait_exit
    th = Thread.list.find { _1.name == "clover_test" }
    r = th[:clover_test_in]
    r.read
    pop "done"
  end

  def hop_entry
    hop :hop_exit
  end

  def hop_exit
    pop({msg: "hop finished"})
  end

  def reaper
    reap
    nap 0
  end

  def napper
    nap(123)
  end

  def popper
    pop({msg: "popped"})
  end
end
