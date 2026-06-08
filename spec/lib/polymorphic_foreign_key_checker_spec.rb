# frozen_string_literal: true

RSpec.describe PolymorphicForeignKeyChecker do
  it "checks polymorphic foreign keys and reports invalid references" do
    expect(described_class.check_all).to be_empty
    account = Account.create(email: "test@example.com")
    project_id = account.create_project_with_default_policy("Default").id
    expect(described_class.check_all).to be_empty
    account.remove_project(project_id)
    account.this.delete(force: true)
    expect(described_class.check_all).to eq [[:applied_subject_tag, :subject_id, [account.ubid]]]
  end
end
