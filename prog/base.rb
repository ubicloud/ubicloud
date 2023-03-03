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
    if @strand.parent_id.nil?
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

  class Hop < RuntimeError
    def initialize(old_label, strand)
      @old_label = old_label
      @strand = strand
    end

    def to_s
      "hop #{@strand.prog}: #{@old_label} -> #{@strand.label}"
    end
  end

  # A hop is a kind of jump, as in, like a jump instruction.
  def hop(label)
    label = label.to_s if label.is_a?(Symbol)
    old_label = @strand.label
    @strand.update(label: label)
    fail Hop.new(old_label, @strand)
  end
end
