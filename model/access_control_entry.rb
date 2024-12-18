# frozen_string_literal: true

require_relative "../model"

class AccessControlEntry < Sequel::Model
  many_to_one :project

  include ResourceMethods

  # :nocov:
  def self.convert_to_tag(klass, project_id, ap_id, i, values, failures)
    # No need to build single-element tags
    return values unless values.is_a?(Array)

    tag = klass.new_with_id(project_id:, name: "Access-Policy-#{ap_id}-#{i}")
    old_values = values
    values, issues = tag.check_members_to_add(values)
    unless issues.empty?
      failures << [project_id, ap_id, i, klass.name, :member_check_failed, issues, old_values - values]
    end
    [tag, values]
  end

  def self.save_converted_access_policy_rows(rows)
    aces, failures = convert_access_policy_rows(rows).values_at(:aces, :failures)
    keys = [:subject_id, :action_id, :object_id]
    aces = aces.map do |ace|
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
    {aces:, failures:}
  end

  def self.convert_access_policy_rows(rows)
    aces, failures = parse_access_policy_rows(rows).values_at(:aces, :failures)
    aces = aces.map do |project_id, ap_id, i, subject_id, action_id, object_id|
      subject_id = convert_to_tag(SubjectTag, project_id, ap_id, i, subject_id, failures)
      action_id = convert_to_tag(ActionTag, project_id, ap_id, i, action_id, failures)
      object_id = convert_to_tag(ObjectTag, project_id, ap_id, i, object_id, failures)
      AccessControlEntry.new_with_id(project_id:, subject_id:, action_id:, object_id:)
    end
    {aces:, failures:}
  end

  def self.parse_access_policy_rows(rows)
    aces = []
    failures = []
    action_map = {
      "Project:delete" => "ffffffff-ff00-835a-87c1-6901ae0bb4e0",
      "Project:edit" => "ffffffff-ff00-835a-87ff-f05a407343a0",
      "Project:view" => "ffffffff-ff00-835a-87ff-f05a40d85dc0",
      "Project:user" => "ffffffff-ff00-835a-87ff-f05a40de5d80",
      "Project:billing" => "ffffffff-ff00-835a-802d-202c21086b00",
      "Project:github" => "ffffffff-ff00-835a-87c1-690201d476b0",
      "Project:subjtag" => "ffffffff-ff00-835a-802d-20676b969500",
      "Project:acttag" => "ffffffff-ff00-835a-87c1-69014cd69500",
      "Project:objtag" => "ffffffff-ff00-835a-87c1-69000b969500",
      "Project:viewaccess" => "ffffffff-ff00-835a-802d-206c2ee298c0",
      "Project:editaccess" => "ffffffff-ff00-835a-802d-2039a1d298c0",
      "Project:token" => "ffffffff-ff00-835a-87fe-0b481a04dd50",
      "Vm:create" => "ffffffff-ff00-835a-87c1-ba019872b4e0",
      "Vm:delete" => "ffffffff-ff00-835a-87c1-ba01ae0bb4e0",
      "Vm:view" => "ffffffff-ff00-835a-87ff-f06e80d85dc0",
      "PrivateSubnet:create" => "ffffffff-ff00-835a-87c1-6c819872b4e0",
      "PrivateSubnet:delete" => "ffffffff-ff00-835a-87c1-6c81ae0bb4e0",
      "PrivateSubnet:edit" => "ffffffff-ff00-835a-87ff-f05b207343a0",
      "PrivateSubnet:view" => "ffffffff-ff00-835a-87ff-f05b20d85dc0",
      "PrivateSubnet:connect" => "ffffffff-ff00-835a-802d-903015ab99a0",
      "PrivateSubnet:disconnect" => "ffffffff-ff00-835a-802d-903439602b50",
      "Firewall:create" => "ffffffff-ff00-835a-87c0-fe019872b4e0",
      "Firewall:delete" => "ffffffff-ff00-835a-87c0-fe01ae0bb4e0",
      "Firewall:edit" => "ffffffff-ff00-835a-87ff-f03f807343a0",
      "Firewall:view" => "ffffffff-ff00-835a-87ff-f03f80d85dc0",
      "LoadBalancer:create" => "ffffffff-ff00-835a-87c0-15819872b4e0",
      "LoadBalancer:delete" => "ffffffff-ff00-835a-87c0-1581ae0bb4e0",
      "LoadBalancer:edit" => "ffffffff-ff00-835a-87ff-f005607343a0",
      "LoadBalancer:view" => "ffffffff-ff00-835a-87ff-f00560d85dc0",
      "Postgres:create" => "ffffffff-ff00-835a-87c1-68019872b4e0",
      "Postgres:delete" => "ffffffff-ff00-835a-87c1-6801ae0bb4e0",
      "Postgres:edit" => "ffffffff-ff00-835a-87ff-f05a007343a0",
      "Postgres:view" => "ffffffff-ff00-835a-87ff-f05a00d85dc0",
      "Postgres:fwedit" => "ffffffff-ff00-835a-87c1-6801fc7343a0",
      "Postgres:fwview" => "ffffffff-ff00-835a-87c1-6801fcd85dc0",
      "Postgres:Firewall:edit" => "ffffffff-ff00-835a-87c1-6801fc7343a0",
      "Postgres:Firewall:view" => "ffffffff-ff00-835a-87c1-6801fcd85dc0",
      "SubjectTag:add" => "ffffffff-ff00-835a-87ff-ff8359029ad0",
      "SubjectTag:remove" => "ffffffff-ff00-835a-87c1-ac830ea036e0",
      "SubjectTag:view" => "ffffffff-ff00-835a-87ff-f06b20d85dc0",
      "ActionTag:add" => "ffffffff-ff00-835a-87ff-ff834a029ad0",
      "ActionTag:remove" => "ffffffff-ff00-835a-87c1-a5030ea036e0",
      "ActionTag:view" => "ffffffff-ff00-835a-87ff-f06940d85dc0",
      "ObjectTag:add" => "ffffffff-ff00-835a-87ff-ff8340029ad0",
      "ObjectTag:remove" => "ffffffff-ff00-835a-87c1-a0030ea036e0",
      "ObjectTag:view" => "ffffffff-ff00-835a-87ff-f06800d85dc0",
      "Project:*" => "ffffffff-ff00-834a-87ff-ff82d2028210",
      "*" => Sequel::NULL,
      "Vm:*" => "ffffffff-ff00-834a-87ff-ff8374028210",
      "PrivateSubnet:*" => "ffffffff-ff00-834a-87ff-ff82d9028210",
      "Firewall:*" => "ffffffff-ff00-834a-87ff-ff81fc028210",
      "LoadBalancer:*" => "ffffffff-ff00-834a-87ff-ff802b028210",
      "Postgres:*" => "ffffffff-ff00-834a-87ff-ff82d0028210"
    }
    name_map = {}
    DB[:access_tag].select_map([:project_id, :name, :hyper_tag_id]).each do |project_id, name, hyper_tag_id|
      (name_map[project_id] ||= {})[name] = hyper_tag_id
    end
    admin_array = ["*"]
    member_array = ["Vm:*", "PrivateSubnet:*", "Firewall:*", "Postgres:*", "Project:view", "Project:github"]

    project_id = nil
    ap_id = nil
    convert = lambda do |i, acl, type, map|
      values = acl[type]
      unless values.is_a?(Array)
        failures << [project_id, ap_id, i, type, :not_array]
        next []
      end
      values = values.map do
        unless (value_id = map[_1])
          failures << [project_id, ap_id, i, type, :unrecognized_name, _1]
        end
        value_id
      end
      values.compact!
      values
    end

    rows.each do |row|
      ap_id, project_id, name, body, managed = row.values_at(:id, :project_id, :name, :body, :managed)
      raise unless project_id

      if managed
        case name
        when "admin"
          is_admin = true
        when "member"
          is_member = true
        else
          failures << [project_id, ap_id, :bad_managed_name, name]
        end
      end

      acls = body["acls"]

      if is_admin
        unless acls.length == 1 && acls[0]["actions"] == admin_array
          failures << [project_id, ap_id, :bad_admin_policy, name]
          next
        end
      elsif is_member
        unless acls.length == 1 && acls[0]["actions"] == member_array
          failures << [project_id, ap_id, :bad_member_policy, name]
          next
        end
        action_id = "ffffffff-ff00-834a-87ff-ff828ea2dd80" # Member global action tag
      end

      unless acls.is_a?(Array)
        failures << [project_id, ap_id, :acls_not_array]
        next
      end

      acls.each_with_index do |acl, i|
        subject_id = convert.call(i, acl, "subjects", name_map[project_id])
        if subject_id.empty?
          failures << [project_id, ap_id, :no_valid_subjects]
          next
        end
        action_id = convert.call(i, acl, "actions", action_map)
        object_id = convert.call(i, acl, "objects", name_map[project_id])
        aces << [project_id, ap_id, i, subject_id, action_id, object_id].map! do
          v = (_1.is_a?(Array) && _1.length == 1) ? _1[0] : _1
          v = nil if v == Sequel::NULL
          v
        end
      end
    end

    {aces:, failures:}
  end
  # :nocov:

  # use __id__ if you want the internal object id
  def_column_alias :object_id, :object_id

  %I[subject action object].each do |type|
    method = :"#{type}_id"
    define_method(:"#{type}_ubid") do
      if (value = send(method))
        UBID.from_uuidish(value).to_s
      end
    end
  end

  def update_from_ubids(hash)
    update(hash.transform_values { UBID.to_uuid(_1) if _1 })
  end

  def validate
    if project_id
      {subject_id:, action_id:, object_id:}.each do |field, value|
        next unless value
        ubid = UBID.from_uuidish(value).to_s
        model = case field
        when :subject_id
          SubjectTag
        when :action_id
          ActionTag
        else
          ObjectTag
        end

        object = ubid.start_with?("et") ? ApiKey.with_pk(value) : UBID.decode(ubid)
        unless model.valid_member?(project_id, object)
          errors.add(field, "is not related to this project")
        end
      end
    end

    super
  end
end

# Table: access_control_entry
# Columns:
#  id         | uuid | PRIMARY KEY
#  project_id | uuid | NOT NULL
#  subject_id | uuid | NOT NULL
#  action_id  | uuid |
#  object_id  | uuid |
# Indexes:
#  access_control_entry_pkey                                       | PRIMARY KEY btree (id)
#  access_control_entry_project_id_subject_id_action_id_object_id_ | btree (project_id, subject_id, action_id, object_id)
# Foreign key constraints:
#  access_control_entry_project_id_fkey | (project_id) REFERENCES project(id)
