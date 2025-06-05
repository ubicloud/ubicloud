# frozen_string_literal: true

class Prog::Base
  attr_reader :strand, :subject_id

  def initialize(strand, snap = nil)
    @snap = snap || SemSnap.new(strand.id)
    @strand = strand
    @subject_id = frame.dig("subject_id") || @strand.id
  end

  def self.subject_is(*names)
    names.each do |name|
      class_eval %(
def #{name}
  @#{name} ||= #{camelize(name.to_s)}[@subject_id]
end
), __FILE__, __LINE__ - 4
      subject_class = Object.const_get(camelize(name.to_s))
      if subject_class.respond_to?(:semaphore_names)
        semaphore(*subject_class.semaphore_names)
      end
    end
  end

  def self.semaphore(*names)
    names.map!(&:intern)
    names.each do |name|
      define_method :"incr_#{name}" do
        @snap.incr(name)
      end

      define_method :"decr_#{name}" do
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

  def self.labels
    @labels || []
  end

  def self.label(label)
    (@labels ||= []) << label

    define_method :"hop_#{label}" do
      dynamic_hop label
    end
  end

  def nap(seconds = 30)
    fail Nap.new(seconds)
  end

  def pop(arg)
    outval = Sequel.pg_jsonb_wrap(
      case arg
      when String
        {"msg" => arg}
      when Hash
        arg
      else
        fail "BUG: must pop with string or hash"
      end
    )

    if strand.stack.length > 0 && (link = frame["link"])
      # This is a multi-level stack with a back-link, i.e. one prog
      # calling another in the same Strand of execution.  The thing to
      # do here is pop the stack entry.
      pg = Page.from_tag_parts("Deadline", strand.id, strand.prog, strand.stack.first["deadline_target"])
      pg&.incr_resolve

      old_prog = strand.prog
      old_label = strand.label
      prog, label = link

      fail Hop.new(old_prog, old_label,
        {retval: outval,
         stack: Sequel.pg_jsonb_wrap(@strand.stack[1..]),
         prog: prog, label: label})
    else
      fail "BUG: expect no stacks exceeding depth 1 with no back-link" if strand.stack.length > 1

      pg = Page.from_tag_parts("Deadline", strand.id, strand.prog, strand.stack.first["deadline_target"])
      pg&.incr_resolve

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
      set_backtrace []
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
      set_backtrace []
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
      set_backtrace []
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
    new_frame = {"subject_id" => @subject_id, "link" => [strand.prog, old_label]}.merge(new_frame)

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
    nap 1
  end

  def reap
    reapable = strand.children_dataset.where(
      Sequel.lit("(lease IS NULL OR lease < now()) AND exitval IS NOT NULL")
    ).all

    reaped_ids = reapable.map do |child|
      # Clear any semaphores that get added to a exited Strand prog,
      # since incr is entitled to be run at *any time* (including
      # after exitval is set, though it doesn't do anything) and any
      # such incements will prevent deletion of a Strand via
      # foreign_key
      Semaphore.where(strand_id: child.id).destroy
      child.destroy
      child.id
    end.freeze

    strand.children.delete_if { reaped_ids.include?(it.id) }

    reapable
  end

  def leaf?
    strand.children.empty?
  end

  # A hop is a kind of jump, as in, like a jump instruction.
  private def dynamic_hop(label)
    fail "BUG: #hop only accepts a symbol" unless label.is_a? Symbol
    fail "BUG: not valid hop target" unless self.class.labels.include? label
    label = label.to_s
    fail Hop.new(@strand.prog, @strand.label, {label: label, retval: nil})
  end

  def register_deadline(deadline_target, deadline_in, allow_extension: false)
    current_frame = strand.stack.first
    if (deadline_at = current_frame["deadline_at"]).nil? ||
        (old_deadline_target = current_frame["deadline_target"]) != deadline_target ||
        allow_extension ||
        Time.parse(deadline_at.to_s) > Time.now + deadline_in

      if old_deadline_target != deadline_target && (pg = Page.from_tag_parts("Deadline", strand.id, strand.prog, old_deadline_target))
        pg.incr_resolve
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
