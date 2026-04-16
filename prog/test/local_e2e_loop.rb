# frozen_string_literal: true

class Prog::Test::LocalE2eLoop < Prog::Test::Base
  ALLOWED_PROGS = %w[
    PostgresResource
    HaPostgresResource
    UpgradePostgresResource
  ].freeze

  semaphore :pause

  def self.check_prog(prog)
    raise "invalid local E2E prog" unless ALLOWED_PROGS.include?(prog)
  end

  def self.assemble(progs:, nap_between: 60, **args)
    progs.each { check_prog(it) }

    Strand.create(
      prog: name.delete_prefix("Prog::"),
      label: "start",
      stack: [{
        "progs" => progs,
        "prog_args" => args,
        "starts" => 0,
        "successes" => 0,
        "failures" => 0,
        "nap" => false,
        "nap_between" => nap_between.clamp(0, nil),
        "current_strand" => nil,
      }],
    )
  end

  def before_run
    super

    if pause_set?
      nap(60 * 60)
    end
  end

  label def start
    st = Prog::Test.const_get(frame["progs"].first).assemble(**frame["prog_args"].transform_keys(&:to_sym))
    st.update(parent_id: strand.id)
    update_stack(
      "current_strand" => st.id,
      "starts" => frame["starts"] + 1,
      "progs" => frame["progs"].rotate,
    )
    hop_wait
  end

  label def wait
    reap(:nap_between, reaper: lambda do |child|
      key = (child.exitval["msg"] == "Postgres tests are finished!") ? "successes" : "failures"
      update_stack(
        "current_strand" => nil,
        key => frame[key] + 1,
        "nap" => true,
      )
    end)
  end

  label def nap_between
    if frame["nap"]
      update_stack("nap" => false)
      nap frame["nap_between"]
    else
      hop_start
    end
  end
end
