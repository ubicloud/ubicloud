# frozen_string_literal: true

require_relative "../model"

class Strand < Sequel::Model
  LEASE_EXPIRATION = 120
  many_to_one :parent, key: :parent_id, class: self
  one_to_many :children, key: :parent_id, class: self

  def lease
    self.class.lease(id) do
      yield self
    end
  end

  def self.prog_verify(prog)
    case prog.name
    when /\AProg::(.*)\z/
      $1
    else
      fail "BUG"
    end
  end

  def self.lease(id)
    affected = DB[<<SQL, id].first
UPDATE strand
SET lease = now() + '120 seconds', schedule = now()
WHERE id = ? AND (lease IS NULL OR lease < now())
RETURNING lease
SQL
    return false unless affected
    lease = affected.fetch(:lease)

    begin
      yield
      true
    ensure
      num_updated = DB[<<SQL, id, lease].update
UPDATE strand
SET lease = NULL
WHERE id = ? AND lease = ?
SQL
      # Avoid leasing integrity check error if the record disappears
      # entirely.
      fail "BUG: lease violated" unless num_updated == 1 || !@deleted
    end
  end

  def load
    Object.const_get("::Prog::" + prog).new(self)
  end

  def unsynchronized_run
    prog = load
    puts "running " + prog.class.to_s
    DB.transaction do
      prog.public_send(label)
    rescue Prog::Base::Nap => e
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
    rescue Prog::Base::Hop => e
      puts e.to_s
    rescue Prog::Base::Exit => e
      puts e.to_s
      delete
      @deleted = true
    end
    puts "ran " + prog.class.to_s

    prog
  end

  def run
    fail "already deleted" if @deleted
    lease do
      next unsynchronized_run
    end
  end
end
