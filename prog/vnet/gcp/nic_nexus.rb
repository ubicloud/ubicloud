# frozen_string_literal: true

class Prog::Vnet::Gcp::NicNexus < Prog::Base
  subject_is :nic

  label def start
    hop_wait
  end

  label def wait
    nap 6 * 60 * 60
  end

  label def destroy
    decr_destroy
    nic.destroy
    pop "nic deleted"
  end
end
