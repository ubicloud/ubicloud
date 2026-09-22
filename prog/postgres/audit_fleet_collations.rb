# frozen_string_literal: true

# On-demand fleet audit: fans out one AuditResourceCollation child per Postgres
# primary (bounded by concurrency), reaps their verdicts, and emits a summary.
# Read replicas are skipped -- they share their parent's data directory lineage,
# so the parent's audit already covers them.
#
# The summary lists both flagged and unreachable resources by id: an unreachable
# resource could not be verified, so it needs manual review before a migration
# just like a flagged one. Neither is safe to treat as clean.
#
# Trigger from a console:
#   Prog::Postgres::AuditFleetCollations.assemble
class Prog::Postgres::AuditFleetCollations < Prog::Base
  frame_reader :todo, :in_progress, :flagged, :clean, :skipped, :unreachable, :concurrency

  def self.assemble(concurrency: 10)
    todo = PostgresServer
      .where(is_representative: true)
      .where(resource_id: PostgresResource.where(parent_id: nil).select(:id))
      .select_map(:resource_id)

    Strand.create(
      prog: "Postgres::AuditFleetCollations",
      label: "wait",
      stack: [{
        "todo" => todo,
        "in_progress" => [],
        "flagged" => [],
        "clean" => [],
        "skipped" => [],
        "unreachable" => [],
        "concurrency" => concurrency,
      }],
    )
  end

  label def wait
    reaper = lambda do |child|
      resource_id = child.stack.first["subject_id"]
      in_progress.delete(resource_id)
      case child.exitval["msg"]
      when "flagged" then flagged.push(resource_id)
      when "clean" then clean.push(resource_id)
      when "unreachable" then unreachable.push(resource_id)
      else skipped.push(resource_id)
      end
    end

    reap(fallthrough: true, reaper:) do
      if todo.empty? && in_progress.empty?
        Clog.emit("postgres fleet collation audit completed", {postgres_fleet_collation_audit: {
          flagged:,
          flagged_count: flagged.count,
          unreachable:,
          unreachable_count: unreachable.count,
          clean: clean.count,
          skipped: skipped.count,
        }})
        pop({"msg" => "fleet collation audit completed", "flagged" => flagged, "unreachable" => unreachable, "clean" => clean.count, "skipped" => skipped.count})
      end
    end

    slots_to_fill = concurrency - strand.children_dataset.count
    while slots_to_fill > 0 && !todo.empty?
      resource_id = todo.shift
      bud Prog::Postgres::AuditResourceCollation, {"subject_id" => resource_id}
      in_progress.push(resource_id)
      slots_to_fill -= 1
    end

    strand.modified!(:stack)
    strand.save_changes
    nap 10
  end
end
