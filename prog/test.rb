# frozen_string_literal: true

# A no-operation prog for testing.
class Prog::Test < Prog::Base
  subject_is :sshable
  semaphore :test_semaphore

  def start
  end

  def pusher1
    pop "1" if retval
    push Prog::Test, {test_level: "2"}, :pusher2
  end

  def pusher2
    pop frame[:test_level] if retval
    push Prog::Test, {test_level: "3"}, :pusher3
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
    # below loop is only for ensuring we are able to process reaped strands
    reap.each do |st|
      st.fetch(:exitval)
    end
    donate
  end

  def napper
    nap(123)
  end

  def popper
    pop({msg: "popped"})
  end

  def invalid_hop
    hop "hop_exit"
  end

  def budder
    bud self.class, frame, :popper
    hop :reaper
  end

  def increment_semaphore
    incr_test_semaphore
    donate
  end

  def decrement_semaphore
    decr_test_semaphore
    donate
  end

  def set_expired_deadline
    register_deadline(:pusher2, -1)
    hop :pusher1
  end

  def set_popping_deadline1
    push Prog::Test, {}, :set_popping_deadline2
  end

  def set_popping_deadline2
    register_deadline(:pusher2, -1)
    hop :popper
  end

  def bad_pop
    pop nil
  end
end
