# frozen_string_literal: true

# A no-operation prog for testing.
class Prog::Test < Prog::Base
  subject_is :sshable
  semaphore :test_semaphore

  label def start
  end

  label def pusher1
    pop "1" if retval
    push Prog::Test, {test_level: "2"}, :pusher2
  end

  label def pusher2
    pop frame[:test_level] if retval
    push Prog::Test, {test_level: "3"}, :pusher3
  end

  label def pusher3
    pop frame[:test_level]
  end

  label def synchronized
    th = Thread.list.find { _1.name == "clover_test" }
    w = th[:clover_test_in]
    th.thread_variable_set(:clover_test_out, Thread.current)
    w.close
    pop "done"
  end

  label def wait_exit
    th = Thread.list.find { _1.name == "clover_test" }
    r = th[:clover_test_in]
    r.read
    pop "done"
  end

  label def hop_entry
    hop_hop_exit
  end

  label def hop_exit
    pop({msg: "hop finished"})
  end

  label def reaper
    # below loop is only for ensuring we are able to process reaped strands
    reap.each do |st|
      st.exitval
    end
    donate
  end

  label def napper
    nap(123)
  end

  label def popper
    pop({msg: "popped"})
  end

  label def invalid_hop
    dynamic_hop "hop_exit"
  end

  label def invalid_hop_target
    dynamic_hop :black_hole
  end

  label def budder
    bud self.class, frame, :popper
    hop_reaper
  end

  label def increment_semaphore
    incr_test_semaphore
    donate
  end

  label def decrement_semaphore
    decr_test_semaphore
    donate
  end

  label def set_expired_deadline
    register_deadline(:pusher2, -1)
    hop_pusher1
  end

  label def set_popping_deadline1
    push Prog::Test, {}, :set_popping_deadline2
  end

  label def set_popping_deadline2
    register_deadline(:pusher2, -1)
    hop_popper
  end

  label def bad_pop
    pop nil
  end
end
