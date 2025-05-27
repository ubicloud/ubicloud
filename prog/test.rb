# frozen_string_literal: true

# A no-operation prog for testing.
class Prog::Test < Prog::Base
  subject_is :sshable
  semaphore :test_semaphore

  label def start
  end

  private def fib(n)
    if n < 2
      1
    else
      fib(n - 2) + fib(n - 1)
    end
  end

  megabyte = (" " * 1024 * 1024)

  3.times do |n|
    n1 = n + 1
    label(define_method(:"smoke_test_#{n1}") do
      when_test_semaphore_set? do
        decr_test_semaphore
        dynamic_hop :"smoke_test_#{n}"
      end

      incr_test_semaphore

      # CPU
      fib(rand(15...25))

      # IO
      rand(20).times do
        File.write(File::NULL, megabyte)
      end

      print n1
      nap rand
    end)
  end

  label def smoke_test_0
    nap 1000
  end

  label def pusher1
    pop "1" if retval
    push Prog::Test, {test_level: "2"}, :pusher2
  end

  label def pusher2
    pop frame["test_level"] if retval
    push Prog::Test, {test_level: "3"}, :pusher3
  end

  label def pusher3
    pop frame["test_level"]
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

  label def reap_exit_no_children
    reap
    pop({msg: "reap_exit_no_children"}) if leaf?
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
    register_deadline("pusher2", -1)
    hop_pusher1
  end

  label def extend_deadline
    register_deadline("pusher2", 1, allow_extension: true)
    hop_pusher1
  end

  label def set_popping_deadline1
    push Prog::Test, {}, :set_popping_deadline2
  end

  label def set_popping_deadline_via_bud
    bud Prog::Test, {}, :set_popping_deadline2
    hop_reaper
  end

  label def set_popping_deadline2
    register_deadline("pusher2", -1)
    hop_popper
  end

  label def bad_pop
    pop nil
  end

  label def push_subject_id
    push Prog::Test, {"subject_id" => "70b633b7-1d24-4526-a47f-d2580597d53f"}
  end
end

class Prog::Test2 < Prog::Test
end
