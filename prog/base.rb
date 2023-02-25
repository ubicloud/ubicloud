# frozen_string_literal: true

class Prog::Base
  attr_reader :strand

  def initialize(strand)
    @strand = strand
    @deleted = false
  end

  def deleted?
    @deleted
  end

  def pop(o)
    if @strand.parent.nil?
      # Should log `o`: there's no supervising strand to collect the
      # result. There's no logging idiom at time of writing this
      # message, though.
      @strand.delete
      @deleted = true
    else
      # Should pop a stack frame, but don't want to bother when I
      # wrote this.
      update(retval: Sequel.pg_jsonb(o))
    end
  end
end
