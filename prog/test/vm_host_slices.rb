# frozen_string_literal: true

require "json"

class Prog::Test::VmHostSlices < Prog::Test::Base
  label def start
    hop_verify_separation
  end

  label def verify_separation
    slices.combination(2) do |slice1, slice2|
      fail_test "Standard instances placed in the same slice" if slice1.id == slice2.id
      fail_test "Standard instances are sharing at least one cpu" if !(slice1.cpus.map(&:cpu_number) & slice2.cpus.map(&:cpu_number)).empty?
    end

    hop_verify_on_host
  end

  label def verify_on_host
    slices.each do |slice|
      slice.vm_host.sshable.start_fresh_session do |session|
        fail_test "Slice #{slice.id} is not setup correctly" unless slice.up? session
      end
    end

    hop_finish
  end

  label def finish
    pop "Verified VM Host Slices!"
  end

  label def failed
    nap 15
  end

  def slices
    @slices ||= frame["slices"].map { VmHostSlice[_1] }
  end
end
