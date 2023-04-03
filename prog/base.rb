# frozen_string_literal: true

class Prog::Base
  attr_reader :strand

  def initialize(strand)
    @strand = strand
  end

  def nap(seconds = 30)
    fail Nap.new(seconds)
  end

  def pop(o)
    outval = case o
    when nil
      nil
    else
      Sequel.pg_jsonb_wrap(o)
    end

    if strand.stack.length > 0 && (link = frame[:link])
      # This is a multi-level stack with a back-link, i.e. one prog
      # calling another in the same Strand of execution.  The thing to
      # do here is pop the stack entry.
      old_prog = strand.prog
      old_label = strand.label
      prog, label = link

      @strand.update(retval: outval,
        stack: Sequel.pg_jsonb_wrap(@strand.stack[1..]),
        prog: prog, label: label)
      fail Hop.new(old_prog, old_label, @strand)
    else
      fail "BUG: expect no stacks exceeding depth 1 with no back-link" if strand.stack.length > 1

      # Child strand with zero or one stack frames, set exitval. Clear
      # retval to avoid confusion, as it would have been set in a
      # previous intra-strand stack pop.
      @strand.update(exitval: outval, retval: nil)
      fail Exit.new(strand)
    end
  end

  class FlowControl < RuntimeError; end

  class Exit < FlowControl
    def initialize(strand)
      @strand = strand
    end

    def to_s
      "Strand exits from #{@strand.prog}##{@strand.label} with #{@strand.exitval}"
    end
  end

  class Hop < FlowControl
    def initialize(old_prog, old_label, strand)
      @old_prog = old_prog
      @old_label = old_label
      @strand = strand
    end

    def to_s
      "hop #{@old_prog}##{@old_label} -> #{@strand.prog}##{@strand.label}"
    end
  end

  class Nap < FlowControl
    attr_reader :seconds

    def initialize(seconds)
      @seconds = seconds
    end

    def to_s
      "nap for #{seconds} seconds"
    end
  end

  def frame
    strand.stack[0]
  end

  def retval
    strand.retval
  end

  def push(prog, frame, label = "start")
    old_prog = strand.prog
    old_label = strand.label
    frame = frame.merge(link: [strand.prog, old_label])
    # YYY: Use in-database jsonb prepend rather than re-rendering a
    # new value doing the prepend.
    @strand.update(prog: Strand.prog_verify(prog), label: label,
      stack: [frame] + strand.stack, retval: nil)
    fail Hop.new(old_prog, old_label, @strand)
  end

  def bud(prog, frame, label = "start")
    Strand.create(parent_id: strand.id,
      prog: Strand.prog_verify(prog), label: label,
      stack: Sequel.pg_jsonb_wrap([frame]))
  end

  def donate
    strand.children.map(&:run)
    nap 0
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
    old_prog = @strand.prog
    old_label = @strand.label
    @strand.update(label: label)
    fail Hop.new(old_prog, old_label, @strand)
  end
end
