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
    if strand.stack.length > 1
      # This is a multi-level stack, i.e. one prog calling another in
      # the same Strand of execution.  The thing to do here is pop the
      # stack entry ...
      #
      # YYY: ... and rewrite the prog and label part the record to the
      # caller, which can also read retval.
      @strand.update(retval: Sequel.pg_jsonb_wrap(o),
        stack: Sequel.pg_jsonb_wrap(@strand.stack[1..]))
    elsif @strand.parent_id.nil?
      # Root strands with zero or one stack frames have no supervisor
      # to reap them: delete.
      #
      # YYY: improve audit logging here.
      @strand.delete
      @deleted = true
    else
      # Child strand with zero or one stack frames, set exitval. Clear
      # retval to avoid confusion, as it would have been set in a
      # previous intra-strand stack pop.
      @strand.update(exitval: Sequel.pg_jsonb_wrap(o), retval: nil)
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

  def frame
    strand.stack[0]
  end

  def bud(prog, stack, label = "start")
    Strand.create(parent_id: strand.id,
      prog: Strand.prog_verify(prog), label: label,
      stack: Sequel.pg_jsonb_wrap([stack]))
  end

  # Translocation is a process in plants whereby chemical feedstocks
  # are moved through tubes to where they need to go.  In this case,
  # we are translocating CPU time from parent to child strands.
  def translocate
    strand.children.map(&:run)
  end

  def reap
    strand.children_dataset.where(Sequel.~(exitval: nil)).returning.delete.tap {
      # Clear cache if anything was deleted.
      strand.associations.delete(:children) unless _1.nil?
    }
  end

  def leaf?
    strand.children.empty?
  end

  # A hop is a kind of jump, as in, like a jump instruction.
  def hop(label)
    label = label.to_s if label.is_a?(Symbol)
    old_label = @strand.label
    @strand.update(label: label)
    fail Hop.new(old_label, @strand)
  end
end
