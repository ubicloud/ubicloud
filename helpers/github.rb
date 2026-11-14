# frozen_string_literal: true

class Clover
  def format_time_diff(start_time, end_time)
    diff = (end_time - start_time).to_i
    h, diff = diff.divmod(3600)
    m, s = diff.divmod(60)

    result = []
    result << "#{h}h" if h > 0
    result << "#{m}m" if m > 0
    result << "#{s}s" if s > 0
    result.empty? ? "0s" : result.join(" ")
  end

  def github_workflow_run_status_label(run)
    if run.status == "completed"
      case run.conclusion
      when "success"
        ["Success", "bg-green-100 text-green-800"]
      when "failure", "timed_out", "startup_failure"
        [run.conclusion.tr("_", " ").capitalize, "bg-red-100 text-red-800"]
      when "action_required"
        ["Action required", "bg-yellow-100 text-yellow-800"]
      when nil
        ["Completed", "bg-slate-100 text-slate-800"]
      else
        [run.conclusion.tr("_", " ").capitalize, "bg-slate-100 text-slate-800"]
      end
    elsif run.status == "in_progress"
      ["In progress", "bg-blue-100 text-blue-800"]
    else
      [run.status.tr("_", " ").capitalize, "bg-yellow-100 text-yellow-800"]
    end
  end
end
