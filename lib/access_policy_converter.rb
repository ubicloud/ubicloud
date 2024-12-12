# frozen_string_literal: true

module AccessPolicyConverter
  # :nocov:
  def self.convert_to_tag(klass, project_id, name, values, failures)
    # No need to build single-element tags
    return values unless values.is_a?(Array)

    tag = klass.new_with_id(project_id:, name:)
    old_values = values
    values, issues = tag.check_members_to_add(values)
    unless issues.empty?
      failures << [:member_check_failed, project_id, name, klass.name, issues, old_values - values]
    end
    [tag, values]
  end

  def self.save_converted_access_policy_rows(rows)
    projects, failures = convert_access_policy_rows(rows).values_at(:projects, :failures)
    keys = [:subject_id, :action_id, :object_id]
    projects.each do |project_id, hash|
      hash[:aces] = hash[:aces].map do |ace|
        keys.each do |key|
          value = ace.send(key)
          if value.is_a?(Array)
            tag, values = value
            tag.save_changes
            tag.add_members(values)
            ace[key] = tag.id
          end
        end
        ace.save_changes
      end
    end
    {projects:, failures:}
  end

  def self.convert_access_policy_rows(rows)
    projects, failures = parse_access_policy_rows(rows).values_at(:projects, :failures)
    keys = [:subject_id, :action_id, :object_id]
    projects.each do |project_id, hash|
      aces = hash[:aces] = hash[:aces].map do |ap_id, i, subject_id, action_id, object_id|
        tag_name = "Access-Policy-#{ap_id}-#{i}"
        subject_id = convert_to_tag(SubjectTag, project_id, tag_name, subject_id, failures)
        action_id = convert_to_tag(ActionTag, project_id, tag_name, action_id, failures)
        object_id = convert_to_tag(ObjectTag, project_id, tag_name, object_id, failures)
        ace = AccessControlEntry.new_with_id(project_id:, subject_id:, action_id:, object_id:)
        subject_id, action_id, object_id = ace.values.values_at(:subject_id, :action_id, :object_id)
        keys.each do |column|
          ace[column] = nil if ace[column].is_a?(Array)
        end
        unless ace.valid?
          ace.errors.delete(:subject_id) if ace.subject_id.nil?
          unless ace.errors.empty?
            failures << [:ace_validation_failed, project_id, ap_id, i, subject_id, action_id, object_id, ace.errors]
          end
        end
        ace.subject_id, ace.action_id, ace.object_id = subject_id, action_id, object_id
        ace
      end

      admin_tag = convert_to_tag(SubjectTag, project_id, "Admin", hash[:admin], failures)
      aces << AccessControlEntry.new_with_id(project_id:, subject_id: admin_tag)

      member_tag = convert_to_tag(SubjectTag, project_id, "Member", hash[:member], failures)
      aces << AccessControlEntry.new_with_id(project_id:, subject_id: member_tag, action_id: "ffffffff-ff00-834a-87ff-ff828ea2dd80") # Member global action tag
      hash.delete(:admin)
      hash.delete(:member)
    end
    {projects:, failures:}
  end

  def self.parse_access_policy_rows(rows)
    projects = {}
    failures = []
    action_map = {
      "Postgres:Firewall:edit" => "ffffffff-ff00-835a-87ff-f05a007343a0",
      "Postgres:Firewall:view" => "ffffffff-ff00-835a-87ff-f05a00d85dc0",
      "Project:*" => "ffffffff-ff00-834a-87ff-ff82d2028210",
      "*" => Sequel::NULL,
      "Vm:*" => "ffffffff-ff00-834a-87ff-ff8374028210",
      "PrivateSubnet:*" => "ffffffff-ff00-834a-87ff-ff82d9028210",
      "Firewall:*" => "ffffffff-ff00-834a-87ff-ff81fc028210",
      "LoadBalancer:*" => "ffffffff-ff00-834a-87ff-ff802b028210",
      "Postgres:*" => "ffffffff-ff00-834a-87ff-ff82d0028210"
    }.merge(ActionType::NAME_MAP)
    name_map = {}
    account_project_set = {}
    DB[:access_tag].select_map([:project_id, :name, :hyper_tag_id, :hyper_tag_table]).each do |project_id, name, hyper_tag_id, table|
      (name_map[project_id] ||= {})[name] = hyper_tag_id
      account_project_set[project_id] ||= true if table == "accounts"
    end
    inactive_project_set = DB[:project].exclude(:visible).select_hash(:id, Sequel[true].as(:v))
    admin_array = ["*"]
    member_array = ["Vm:*", "PrivateSubnet:*", "Firewall:*", "Postgres:*", "Project:view", "Project:github"]

    project_id = nil
    ap_id = nil
    convert = lambda do |i, acl, type, map|
      values = acl[type]
      unless values.is_a?(Array)
        failures << [:not_array, project_id, ap_id, i, type]
        next []
      end
      values = values.map do
        unless (value_id = map[_1])
          failures << [:unrecognized_name, project_id, ap_id, i, type, _1]
        end
        value_id
      end
      values.compact!
      values
    end

    rows.each do |row|
      ap_id, project_id, name, body, managed = row.values_at(:id, :project_id, :name, :body, :managed)
      raise unless project_id
      next if inactive_project_set[project_id] # Ignore soft-deleted projects
      next unless account_project_set[project_id] # Ignore projects without accounts

      acls = body["acls"]

      if managed
        case name
        when "admin"
          is_admin = true
          unless acls.length == 1 && acls[0]["actions"] == admin_array
            failures << [:bad_admin_policy, project_id, ap_id, name]
            next
          end
        when "member"
          is_member = true
          unless acls.length == 1 && member_array.all? { acls[0]["actions"].include?(_1) }
            failures << [:bad_member_policy, project_id, ap_id, name, acls]
            next
          end
        else
          failures << [:bad_managed_name, project_id, ap_id, name]
        end
      end

      unless acls.is_a?(Array)
        failures << [:acls_not_array, project_id, ap_id]
        next
      end

      acls.each_with_index do |acl, i|
        subject_id = convert.call(i, acl, "subjects", name_map[project_id])
        if subject_id.empty?
          unless acl["subjects"].empty?
            failures << [:no_valid_subjects, project_id, ap_id, i]
          end
          next
        end

        ace_hash = projects[project_id] ||= {admin: [], member: [], aces: []}
        # Project:policy is not a valid action, but it was used previously.  If a user was
        # granted the ability to change the project policy, de facto they are equivalent to an
        # admin of the project, since they could change the policy to grant themselves any
        # access they needed.
        if is_admin || acl["actions"] == admin_array || acl["actions"].include?("Project:policy")
          ace_hash[:admin].concat(subject_id)
          subject_id = []
        elsif is_member
          api_keys, subject_id = subject_id.partition { UBID.from_uuidish(_1).to_s.start_with?("et") }
          ace_hash[:member].concat(subject_id)
          subject_id = api_keys.map { [_1] }
        else
          api_keys, subject_id = subject_id.partition { UBID.from_uuidish(_1).to_s.start_with?("et") }
          subject_id = [subject_id] + api_keys.map { [_1] }
        end

        subject_id.each do |subject_id|
          action_id = convert.call(i, acl, "actions", action_map)
          object_id = convert.call(i, acl, "objects", name_map[project_id])
          ace_hash[:aces] << [ap_id, i, subject_id, action_id, object_id].map! do
            v = (_1.is_a?(Array) && _1.length == 1) ? _1[0] : _1
            v = nil if v == Sequel::NULL
            v
          end
        end
      end
    end

    projects.each do |project_id, hash|
      admin = hash[:admin]
      if admin.empty?
        project_accounts = Project[project_id].accounts

        if project_accounts.length == 1
          # If a project has only a single account, that account is the admin
          admin.concat(project_accounts.map(&:id))
        else
          failures << [:no_admin_members, project_id]
        end
      else
        hash[:aces].delete_if do
          # No point in separate AccessControlEntry if subject has full admin access
          admin.include?(_1[2])
        end
      end
    end

    {projects:, failures:}
  end
  # :nocov:
end
