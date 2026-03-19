# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "audit-log") do |r|
    authorize("Project:auditlog", @project)

    r.get true do
      audit_log_search(DB[:audit_log].where(project_id: @project.id),
        resolve: web? ? :subjects_and_objects : :subjects,
        accounts_dataset: @project.accounts_dataset,
        month_limit: 3)
      ubids = @ubids

      if api?
        result = {}
        result["pagination_key"] = @pagination_key if @pagination_key
        result["items"] = @audit_logs.map do |row|
          subject_id = row[:subject_id]
          item = {
            at: row[:at].getutc.iso8601,
            action: "#{row[:ubid_type]}/#{row[:action]}",
            subject_id: UBID.to_ubid(subject_id),
            object_ids: row[:object_ids].map { UBID.to_ubid(it) }
          }

          if (subject_name = ubids[subject_id]&.name)
            item[:subject_name] = subject_name
          end

          item
        end
        result
      else
        end_date = @end_date
        @audit_logs.each do |log|
          subject_id = log[:subject_id]
          subject_ubid = UBID.to_ubid(subject_id)
          subject_name = ubids[subject_id]&.name || subject_ubid
          log[:subject] = "<a class=\"text-orange-600\" href=\"?end=#{end_date}&amp;subject=#{h subject_ubid}\">#{h subject_name}</a>"

          log[:objects] = log[:object_ids].filter_map do |object_id|
            object_ubid = UBID.to_ubid(object_id)
            if (obj = ubids[object_id]) && obj.respond_to?(:name) && obj.respond_to?(:path)
              "<a class=\"text-orange-600\" href=\"?end=#{end_date}&amp;object=#{h object_ubid}\">#{h obj.name}</a> (<a class=\"text-orange-600\" href=\"#{@project.path}#{obj.path}\">View</a>)"
            else
              "<a class=\"text-orange-600\" href=\"?end=#{end_date}&amp;object=#{h object_ubid}\">#{h object_ubid}</a>"
            end
          end
        end
        view "project/audit_log"
      end
    end

    r.get web?, "authentication" do
      accounts_dataset = @project.accounts_dataset
      authentication_audit_log_search(
        DB[:account_authentication_audit_log].where(account_id: accounts_dataset.select(:id)),
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
