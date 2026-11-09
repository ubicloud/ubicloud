# frozen_string_literal: true

class Prog::Github::GithubActiveWorkflowRunNexus < Prog::Base
  label def start
    DB[:github_active_workflow_run].where(id: @subject_id).delete
    pop "exiting"
  end
  alias_method :destroy, :start
  label :destroy
end
