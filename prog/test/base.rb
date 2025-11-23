# frozen_string_literal: true

class Prog::Test::Base < Prog::Base
  def fail_test(msg)
    strand.update(exitval: {msg: msg})
    hop_failed
  end
end
