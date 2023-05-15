# frozen_string_literal: true

require_relative "../model"

class Strand < Sequel::Model
  LEASE_EXPIRATION = 120
  many_to_one :parent, key: :parent_id, class: self
  one_to_many :children, key: :parent_id, class: self

  NAVIGATE = %w[vm vm_host sshable].freeze

  NAVIGATE.each do
    one_to_one _1.intern, key: :id
  end

  def lease
    self.class.lease(id) do
      yield
    end
  end

  def self.prog_verify(prog)
    case prog.name
    when /\AProg::(.*)\z/
      $1
    else
      fail "BUG: prog must be in Prog module"
    end
  end

  def self.lease(id)
    affected = DB[<<SQL, id].first
UPDATE strand
SET lease = now() + '120 seconds', schedule = now()
WHERE id = ? AND (lease IS NULL OR lease < now())
RETURNING lease, exitval IS NOT NULL AS exited
SQL
    return false unless affected
    lease = affected.fetch(:lease)

    begin
      if affected.fetch(:exited)
        # Clear any semaphores that get added to a exited Strand prog,
        # since incr is entitled to be run at *any time* (including
        # after exitval is set) and any such incements will prevent
        # deletion of a Strand via foreign_key
        Semaphore.where(strand_id: id).delete
        return
      end

      yield
    ensure
      num_updated = DB[<<SQL, id, lease].update
UPDATE strand
SET lease = NULL
WHERE id = ? AND lease = ?
SQL
      # Avoid leasing integrity check error if the record disappears
      # entirely.
      unless num_updated == 1 || !@deleted
        # :nocov:
        fail "BUG: lease violated"
        # :nocov:
      end
    end
  end

  def load(snap = nil)
    Object.const_get("::Prog::" + prog).new(self, snap)
  end

  def unsynchronized_run
    DB.transaction do
      SemSnap.use(id) do |snap|
        load(snap).public_send(label)
      end
    rescue Prog::Base::Nap => e
      return e if e.seconds <= 0
      scheduled = DB[<<SQL, e.seconds, id].get
UPDATE strand
SET schedule = now() + (? * '1 second'::interval)
WHERE id = ?
RETURNING schedule
SQL
      # For convenience, reflect the updated record's schedule content
      # in the model object, but since it's fresh, remove it from the
      # changed columns so save_changes won't update it again.
      self.schedule = scheduled
      changed_columns.delete(:schedule)
      e
    rescue Prog::Base::Hop => e
      e
    rescue Prog::Base::Exit => e
      if parent_id.nil?
        # No parent Strand to reap here, so self-reap.
        Semaphore.where(strand_id: id).delete
        delete
        @deleted = true
      end

      e
    else
      fail "BUG: Prog #{prog}##{label} did not provide flow control"
    end
  end

  def run(seconds = 0)
    fail "already deleted" if @deleted
    deadline = Time.now + seconds
    lease do
      loop do
        ret = unsynchronized_run
        now = Time.now
        if now > deadline ||
            (ret.is_a?(Prog::Base::Nap) && ret.seconds != 0) ||
            ret.is_a?(Prog::Base::Exit)
          return ret
        end
      end
    end
  end
end
