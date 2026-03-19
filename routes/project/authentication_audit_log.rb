# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "authentication-audit-log") do |r|
    authorize("Project:auditlog", @project)

    r.get true do
      accounts_dataset = @project.accounts_dataset
      authentication_audit_log_search(
        DB[:admin_account_authentication_audit_log].where(account_id: accounts_dataset.select(:id)),
        accounts_dataset:,
        resolve: :accounts,
        month_limit: 3
      )
      ubids = @ubids
      end_date = @end_date
      @audit_logs.each do |log|
        account_id = log[:account_id]
        account_ubid = UBID.to_ubid(account_id)
        account_name = ubids[account_id]&.name || account_ubid
        log[:account] = "<a class=\"text-orange-600\" href=\"?end=#{end_date}&amp;account=#{h account_ubid}\">#{h account_name}</a>"
      end
      view "project/authentication_audit_log"
    end
  end
end
