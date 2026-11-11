# frozen_string_literal: true

class Prog::CheckRespirateDelay < Prog::Base
  frame_reader :last_label_changed_at

  label def wait
    if delayed?
      register_deadline("wait", 5 * 60)
      nap_hop(10, :delayed)
    end
    nap 10
  end

  label def delayed
    nap_hop(10, :recovering) unless delayed?
    nap 10
  end

  label def recovering
    nap_hop(10, :delayed) if delayed?
    nap_hop(10, :wait) if Time.now - Time.new(last_label_changed_at) >= 60
    nap 10
  end

  def delayed?
    strand.respirate_metrics.total_delay > 20
  end
end
