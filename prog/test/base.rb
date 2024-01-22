# frozen_string_literal: true

class Prog::Test::Base < Prog::Base
  def fail_test(msg)
    strand.update(exitval: {msg: msg})
    hop_failed
  end

  def update_stack(new_frame)
    strand.stack.first.merge!(new_frame)
    strand.modified!(:stack)
    strand.save_changes
  end
end
