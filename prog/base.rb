# frozen_string_literal: true

class Prog::Base
  attr_reader :strand, :subject_id

  def initialize(strand, snap = nil)
    @snap = snap || SemSnap.new(strand.id)
    @strand = strand
    @subject_id = frame&.dig("subject_id") || @strand.id
  end

  def self.subject_is(*names)
    names.each do |name|
      class_eval %(
def #{name}
  @#{name} ||= #{camelize(name.to_s)}[@subject_id]
end
), __FILE__, __LINE__ - 4
    end
  end

  def self.semaphore(*names)
    names.map!(&:intern)
    names.each do |name|
      define_method "incr_#{name}" do
        @snap.incr(name)
      end

      define_method "decr_#{name}" do
        @snap.decr(name)
      end

      class_eval %{
def when_#{name}_set?
  if @snap.set?(#{name.inspect})
    yield
  end
end
}, __FILE__, __LINE__ - 6
    end
  end

  def nap(seconds = 30)
    fail Nap.new(seconds)
  end

  def pop(*args)
    outval = Sequel.pg_jsonb_wrap(
      case args
      in [String => s]
        {"msg" => s}
      in [Hash => h]
        h
      else
        fail "BUG: must pop with string or hash"
      end
    )

    if strand.stack.length > 0 && (link = frame["link"])
      # This is a multi-level stack with a back-link, i.e. one prog
      # calling another in the same Strand of execution.  The thing to
      # do here is pop the stack entry.
      Page[frame["page_id"]].incr_resolve if frame["page_id"]

      old_prog = strand.prog
      old_label = strand.label
      prog, label = link

      fail Hop.new(old_prog, old_label,
        {retval: outval,
         stack: Sequel.pg_jsonb_wrap(@strand.stack[1..]),
         prog: prog, label: label})
    else
      fail "BUG: expect no stacks exceeding depth 1 with no back-link" if strand.stack.length > 1

      # Child strand with zero or one stack frames, set exitval. Clear
      # retval to avoid confusion, as it would have been set in a
      # previous intra-strand stack pop.
      fail Exit.new(strand, outval)
    end
  end

  class FlowControl < RuntimeError; end

  class Exit < FlowControl
    attr_reader :exitval

    def initialize(strand, exitval)
      @strand = strand
      @exitval = exitval
    end

    def to_s
      "Strand exits from #{@strand.prog}##{@strand.label} with #{@exitval}"
    end
  end

  class Hop < FlowControl
    attr_reader :strand_update_args, :old_prog

    def initialize(old_prog, old_label, strand_update_args)
      @old_prog = old_prog
      @old_label = old_label
      @strand_update_args = strand_update_args
    end

    def new_label
      @strand_update_args[:label] || @old_label
    end

    def new_prog
      @strand_update_args[:prog] || @old_prog
    end

    def to_s
      "hop #{@old_prog}##{@old_label} -> #{new_prog}##{new_label}"
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
    @frame ||= strand.stack.first.dup.freeze
  end

  def retval
    strand.retval
  end

  def push(prog, new_frame = {}, label = "start")
    old_prog = strand.prog
    old_label = strand.label
    new_frame = new_frame.merge("subject_id" => @subject_id, "link" => [strand.prog, old_label])

    # YYY: Use in-database jsonb prepend rather than re-rendering a
    # new value doing the prepend.
    fail Hop.new(old_prog, old_label,
      {prog: Strand.prog_verify(prog), label: label,
       stack: [new_frame] + strand.stack, retval: nil})
  end

  def bud(prog, new_frame = {}, label = "start")
    new_frame = {"subject_id" => @subject_id}.merge(new_frame)
    strand.add_child(
      id: Strand.generate_uuid,
      prog: Strand.prog_verify(prog),
      label: label,
      stack: Sequel.pg_jsonb_wrap([new_frame])
    )
  end

  def donate
    strand.children.map(&:run)
    nap 0
  end

  def reap
    exited_children = strand.children_dataset.where(Sequel.~(exitval: nil)).all

    # Clear cache if anything was deleted.
    strand.associations.delete(:children) if exited_children.count > 0
    exited_children.each(&:destroy)
  end

  def leaf?
    strand.children.empty?
  end

  # A hop is a kind of jump, as in, like a jump instruction.
  def hop(label)
    fail "BUG: #hop only accepts a symbol" unless label.is_a? Symbol
    label = label.to_s
    fail Hop.new(@strand.prog, @strand.label, {label: label, retval: nil})
  end

  def register_deadline(deadline_target, deadline_in)
    current_frame = strand.stack.first
    if (deadline_at = current_frame["deadline_at"]).nil? ||
        Time.parse(deadline_at.to_s) > Time.now + deadline_in ||
        (old_deadline_target = current_frame["deadline_target"]) != deadline_target

      if old_deadline_target != deadline_target && (page_id = current_frame["page_id"])
        Page[page_id].incr_resolve
        current_frame.delete("page_id")
      end

      current_frame["deadline_target"] = deadline_target
      current_frame["deadline_at"] = Time.now + deadline_in

      strand.modified!(:stack)
    end
  end

  # Copied from sequel/model/inflections.rb's camelize, to convert
  # table names into idiomatic model class names.
  private_class_method def self.camelize(s)
    s.gsub(/\/(.?)/) { |x| "::#{x[-1..].upcase}" }.gsub(/(^|_)(.)/) { |x| x[-1..].upcase }
  end
end
