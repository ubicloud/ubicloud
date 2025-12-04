# frozen_string_literal: true

class Prog::Base
  attr_reader :strand, :subject_id

  def initialize(strand, snap = nil)
    @snap = snap || SemSnap.new(strand.id)
    @strand = strand
    @subject_id = frame.dig("subject_id") || @strand.id
  end

  # Searches the stack for the Prog that caused execution of the code,
  # which can be useful in logging from nested method calls.
  def self.current_prog
    caller_locations.reverse_each { return it.label if it.label.start_with?("Prog::") }
    nil
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
    names << :destroying if names.include?(:destroy)
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

    if label == :destroy
      define_method :"hop_#{label}" do
        incr_destroying
        dynamic_hop label
      end
    else
      define_method :"hop_#{label}" do
        dynamic_hop label
      end
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

  EMPTY_ARRAY = [].freeze

  class Exit < FlowControl
    attr_reader :exitval

    def initialize(strand, exitval)
      @strand = strand
      @exitval = exitval
      set_backtrace EMPTY_ARRAY
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
      set_backtrace EMPTY_ARRAY
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
      set_backtrace EMPTY_ARRAY
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

  # Process child strands
  #
  # Reapable children (child strands that have exited) are destroyed.
  # If a reaper argument is given, it is called with each child after
  # the child is destroyed.
  #
  # If there are no reapable children:
  #
  # * If hop is given: hops to the target
  # * If block is given: yields to block
  #
  # If there are still active children:
  #
  # * If fallthrough is given: returns nil
  # * If nap is given: naps for given time
  # * Otherwise, donates to run a child process
  def reap(hop = nil, reaper: nil, nap: nil, fallthrough: false, strand: self.strand)
    children = strand
      .children_dataset
      .order(:schedule)
      .select_append(Sequel.lit("lease < now() AND exitval IS NOT NULL").as(:reapable))
      .all

    reapable_children, active_children = children.partition { it.values.delete(:reapable) }

    reapable_children.each do |child|
      # In case the child strand has its own child strand that needs to be
      # reaped, it should be reaped here, otherwise the child.destroy
      # later results in a foreign key violation.
      reap(fallthrough: true, strand: child)

      # Clear any semaphores that get added to a exited Strand prog,
      # since incr is entitled to be run at *any time* (including
      # after exitval is set, though it doesn't do anything) and any
      # such incements will prevent deletion of a Strand via
      # foreign_key
      child.semaphores_dataset.destroy
      child.destroy
      reaper&.call(child)
    end

    # Parent is now a leaf, hop to given label, or yield if no label
    if active_children.empty?
      if hop
        dynamic_hop(hop)
      elsif block_given?
        yield
      end
    end

    unless fallthrough
      # Parent is not a leaf, nap for given time, or donate if no
      # nap time is given.
      if nap
        nap(nap)
      else
        active_children.each do |child|
          if (result = child.run)
            if result.is_a?(Nap)
              seconds = if active_children.length == 1
                # For a single active child napping, parent can nap for as long as the child naps,
                # since the expectation is there will not be anything to do until then.
                result.seconds
              else
                # For multiple active children, if a single child is napping, it's possible the
                # other children are immediately runnable. However, you don't want to busy
                # wait on multiple children. Nap until the time of the earliest scheduled child
                # that isn't currently running. If all children are running, nap for 120 seconds
                strand.children_dataset
                  .where(Sequel[:lease] < Sequel::CURRENT_TIMESTAMP)
                  .min(Sequel.extract(:epoch, Sequel[:schedule] - Sequel::CURRENT_TIMESTAMP)) || 121
              end

              # Remove a 10th of a second so it is likely the parent will run the child.
              seconds -= 0.1

              # Nap for a minimum of 0.1 seconds and a maximum of 120 seconds in any case.
              # The 0.1 seconds is to avoid busy waiting.
              nap(seconds.clamp(0.1, 120))
            else
              # A non-nap (e.g. Exit or Hop) happened, so the state changed, and
              # it makes sense to rerun the strand immediately.
              nap 0
            end
          end
        end

        schedule = strand.schedule

        # Lock this parent strand. This is run inside a transaction,
        # and will make exited child strands attempting to update the
        # parent's schedule block until the transaction commits.
        strand.lock!(:no_key_update)

        # lock! does an implicit reload, so check the new schedule
        new_schedule = strand.schedule

        # In case the exiting child updated the parent schedule before
        # the lock, check whether the schedule changed. If the schedule
        # changed, assume it was set to CURRENT_TIMESTAMP, and nap 0.
        # Otherwise, nap for 120s and rely on the exiting child strand
        # scheduling this parent sooner in most cases.
        nap((schedule != new_schedule) ? 0 : 120)
      end
    end
  end

  def update_stack(new_frame)
    strand.stack.first.merge!(new_frame)
    strand.modified!(:stack)
    strand.save_changes
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
