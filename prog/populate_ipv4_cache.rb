# frozen_string_literal: true

class Prog::PopulateIpv4Cache < Prog::Base
  label def wait
    Util.populate_ipv4_txt

    nap 60 * 60
  end
end
