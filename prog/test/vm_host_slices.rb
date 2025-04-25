# frozen_string_literal: true

require "json"

class Prog::Test::VmHostSlices < Prog::Test::Base
  label def start
    hop_verify_separation
  end

  label def verify_separation
    slices.combination(2) do |slice1, slice2|
      unless slice1.is_shared && slice2.is_shared # If both slices are shared, they can be the same, but don't have to
        fail_test "Two Vm instances placed in the same slice; slice: #{slice1.id}" if slice1.id == slice2.id
        fail_test "Two Vm instances are sharing at least one cpu; slice1: #{slice1.id}, slice2: #{slice2.id}" if !(slice1.cpus.map(&:cpu_number) & slice2.cpus.map(&:cpu_number)).empty?
      end
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
    @slices ||= frame["slices"].map { VmHostSlice[it] }
  end
end
