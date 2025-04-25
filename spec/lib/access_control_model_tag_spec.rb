# frozen_string_literal: true

[SubjectTag, ActionTag, ObjectTag].each do |model|
  RSpec.describe model do
    let(:user) { Account.create_with_id(email: "auth1@example.com") }
    let(:project) do
      project = Project.create_with_id(name: "project-1")
      user.add_project(project)
      project
    end
    let(:tag) { model.create_with_id(project_id: project.id, name: "test-#{model}") }
    # rubocop:disable RSpec/IndexedLet
    let(:tag1) { model.create_with_id(project_id: project.id, name: "tag1") }
    let(:tag2) { model.create_with_id(project_id: project.id, name: "tag2") }
    # rubocop:enable RSpec/IndexedLet

    it "#add_member adds a member to the tag" do
      expect(tag.member_ids).to be_empty
      tag.add_member(tag1.id)
      expect(tag.member_ids).to eq [tag1.id]
      tag.add_member(tag2.id)
      expect(tag.member_ids.sort).to eq [tag1.id, tag2.id].sort
    end

    it "#add_members adds multiple members to a tag" do
      expect(tag.member_ids).to be_empty
      tag.add_members([tag1.id, tag2.id])
      expect(tag.member_ids.sort).to eq [tag1.id, tag2.id].sort
    end

    it "#remove_members removes multiple members from a tag" do
      expect(tag.member_ids).to be_empty
      tag.add_members([tag1.id, tag2.id])
      expect(tag.member_ids.sort).to eq [tag1.id, tag2.id].sort
      tag.remove_members([tag1.id, tag2.id])
      expect(tag.member_ids).to be_empty
    end

    it "#remove_members moves deleted records to archived_records" do
      tag.add_members([tag1.id, tag2.id])
      tag.remove_members([tag1.id, tag2.id])
      column = model.table_name.to_s.sub("tag", "id")
      rows = DB[:archived_record].where(model_name: "applied_#{model.table_name}").select_map(:model_values)
      expect(rows.length).to eq 2
      expect(rows.map { it["tag_id"] }.uniq).to eq [tag.id]
      expect(rows.map { it[column] }.sort).to eq [tag1.id, tag2.id].sort
    end

    it "#currently_included_in returns all tag ids that directly or indirectly include this tag" do
      expect(tag.currently_included_in).to be_empty
      tag1.add_member(tag.id)
      expect(tag.currently_included_in).to eq [tag1.id]
      tag2.add_member(tag1.id)
      expect(tag.currently_included_in.sort).to eq [tag1.id, tag2.id].sort
    end

    it "#check_members_to_add returns array of ids that can be added and array of issues" do
      expect(tag.check_members_to_add([])).to eq [[], []]
      expect(tag.check_members_to_add([tag.id])).to eq [[], ["cannot include tag in itself"]]

      tag.add_member(tag1.id)
      expect(tag.check_members_to_add([tag1.id])).to eq [[], ["1 members already in tag"]]
      expect(tag.check_members_to_add([tag.id, tag1.id])).to eq [[], ["cannot include tag in itself", "1 members already in tag"]]

      tag2.add_member(tag.id)
      expect(tag.check_members_to_add([tag2.id])).to eq [[], ["1 members already include tag directly or indirectly"]]

      tag.applied_dataset.delete
      expect(tag.check_members_to_add([tag1.id, tag1.id])).to eq [[tag1.id], []]

      expect(tag.check_members_to_add([Page.create(tag: "t").id])).to eq [[], ["1 members not valid"]]
    end

    if model == SubjectTag
      it "#check_members_to_add does not allow including Admin subject tag" do
        expect(tag.check_members_to_add([SubjectTag.create_with_id(project_id: project.id, name: "Admin").id])).to eq [[], ["cannot include Admin subject tag in another tag", "1 members not valid"]]
      end
    end

    it "destroys referenced applied tags and access control entries when destroying" do
      tag1.add_member(tag.id)
      tag.add_member(tag2.id)
      case tag
      when SubjectTag
        subject_id = tag.id
      when ActionTag
        action_id = tag.id
      when ObjectTag
        object_id = tag.id
        meta_id = ObjectMetatag.to_meta_uuid(object_id)
      end
      subject_id ||= SubjectTag.create_with_id(project_id: project.id, name: "t").id
      meta_id ||= tag.id
      ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id:, action_id:, object_id:)
      ace2 = AccessControlEntry.create_with_id(project_id: project.id, subject_id:, action_id:, object_id: meta_id)
      ot = ObjectTag.create_with_id(project_id: project.id, name: "t2")
      ot.add_member(meta_id)

      tag.destroy
      expect(tag1.member_ids).to be_empty
      expect(ace.exists?).to be false
      expect(ace2.exists?).to be false
      expect(ot.member_ids).to be_empty
    end

    it "validates name format" do
      error = "must only include ASCII letters, numbers, and dashes, and must start and end with an ASCII letter or number"
      tag = model.new(project_id: project.id)
      expect(tag.valid?).to be false
      expect(tag.errors[:name]).to eq([error])

      tag.name = "@"
      expect(tag.valid?).to be false
      expect(tag.errors[:name]).to eq([error])

      tag.name = "a"
      tag.valid?
      expect(tag.valid?).to be true

      tag.name = "a-"
      expect(tag.valid?).to be false
      expect(tag.errors[:name]).to eq([error])

      tag.name = "a-b"
      expect(tag.valid?).to be true

      tag.name = "a-#{"b" * 63}"
      expect(tag.valid?).to be false
      expect(tag.errors[:name]).to eq([error])
    end
  end
end
