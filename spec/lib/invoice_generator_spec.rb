# frozen_string_literal: true

# rubocop:disable RSpec/NoExpectationExample
RSpec.describe InvoiceGenerator do
  def generate_billing_record(project, resource, span)
    case resource
    when Vm
      vm = resource
      billing_rate_id = BillingRate.from_resource_properties("VmCores", vm.family, vm.location)["id"]
      amount = vm.cores
      name = vm.name
    when GithubRunner
      gr = resource
      billing_rate_id = BillingRate.from_resource_properties("GitHubRunnerMinutes", Github.runner_labels[gr.label]["vm_size"], "global")["id"]
      name = "foo"
      amount = 5000
    end

    BillingRecord.create_with_id(
      project_id: project.id,
      resource_id: resource.id,
      resource_name: name,
      span: span,
      billing_rate_id: billing_rate_id,
      amount: amount
    )
  end

  def check_invoice_for_single_vm(invoices, project, vm, duration)
    expect(invoices.count).to eq(1)

    br = BillingRate.from_resource_properties("VmCores", vm.family, vm.location)
    duration_mins = [672 * 60, (duration / 60).ceil].min
    cost = (vm.cores * duration_mins * br["unit_price"]).round(3)
    expect(invoices.first.content).to eq({
      "project_id" => project.id,
      "project_name" => project.name,
      "billing_info" => project.billing_info ? {
        "id" => project.billing_info.id,
        "ubid" => project.billing_info.ubid,
        "name" => "ACME Inc.",
        "email" => nil,
        "address" => "",
        "country" => "NL",
        "city" => nil,
        "state" => nil,
        "postal_code" => nil,
        "tax_id" => "123456",
        "company_name" => nil
      } : nil,
      "issuer_info" => {
        "name" => "Ubicloud Inc.",
        "address" => "310 Santa Ana Avenue",
        "country" => "US",
        "city" => "San Francisco",
        "state" => "CA",
        "postal_code" => "94127"
      },
      "resources" => [{
        "resource_id" => vm.id,
        "resource_name" => vm.name,
        "line_items" => [{
          "location" => br["location"],
          "resource_type" => "VmCores",
          "resource_family" => vm.family,
          "description" => "standard-#{vm.cores * 2} Virtual Machine",
          "amount" => vm.cores.to_f,
          "duration" => duration_mins,
          "cost" => cost
        }],
        "cost" => cost
      }],
      "subtotal" => cost,
      "discount" => 0,
      "credit" => 0,
      "cost" => cost
    })
  end

  let(:p1) {
    Account.create_with_id(email: "auth1@example.com")
    Project.create_with_id(name: "cool-project")
  }
  let(:vm1) { create_vm }

  let(:day) { 24 * 60 * 60 }
  let(:begin_time) { Time.parse("2023-06-01") }
  let(:end_time) { Time.parse("2023-07-01") }

  it "does not generate invoice for billing record that started and terminated before this billing window" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 150 * day, begin_time - 90 * day))
    invoices = described_class.new(begin_time, end_time).run
    expect(invoices.count).to eq(0)
  end

  it "generates invoice for billing record started before this billing window and not terminated yet" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, nil))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 30 * day)
  end

  it "generates invoice for billing record started before this billing window and terminated in the future" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, end_time + 90 * day))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 30 * day)
  end

  it "generates invoice for billing record started before this billing window and terminated before end of it" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, begin_time + 15 * day))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 15 * day)
  end

  it "generates invoice for billing record started in this billing window and not terminated yet" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time + 5 * day, nil))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 25 * day)
  end

  it "generates invoice for billing record started in this billing window and terminated in the future" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time + 5 * day, end_time + 90 * day))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 25 * day)
  end

  it "generates invoice for billing record started in this billing window and terminated before end of it" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time + 5 * day, begin_time + 15 * day))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 10 * day)
  end

  it "does not generate invoice for billing record started in a future billing window" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(end_time + 5 * day, end_time + 15 * day))
    invoices = described_class.new(begin_time, end_time).run
    expect(invoices.count).to eq(0)
  end

  it "generates invoice for project with billing info" do
    allow(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)
    expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "metadata" => {"tax_id" => "123456"}, "address" => {"country" => "NL"}}).at_least(:once)

    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, nil))
    bi = BillingInfo.create_with_id(stripe_id: "cs_1234567890")
    p1.update(billing_info_id: bi.id)
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 30 * day)
  end

  it "generates invoice for a single project" do
    p2 = Project.create_with_id(name: "cool-project")
    vm2 = create_vm

    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time, end_time))
    generate_billing_record(p2, vm2, Sequel::Postgres::PGRange.new(begin_time, end_time))

    invoices = described_class.new(begin_time, end_time, project_ids: [p1.id]).run
    expect(invoices.count).to eq(1)
  end

  it "creates invoice record in the database only if save_result is set" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, nil))
    described_class.new(begin_time, end_time, save_result: false).run
    expect(Invoice.count).to eq(0)

    described_class.new(begin_time, end_time, save_result: true).run
    expect(Invoice.count).to eq(1)

    expect(Invoice.first.invoice_number).to eq("#{begin_time.strftime("%y%m")}-#{p1.id[-10..]}-0001")
  end

  it "handles discounts" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, end_time + 90 * day))

    cost_before, discount_before = described_class.new(begin_time, end_time).run.first.content.values_at("cost", "discount")
    p1.update(discount: 10)
    cost_after, discount_after = described_class.new(begin_time, end_time).run.first.content.values_at("cost", "discount")

    expect(cost_after).to eq((cost_before * 0.9).round(3))
    expect(discount_before).to eq(0)
    expect(discount_after).to eq((cost_before * 0.1).round(3))
  end

  it "handles credits" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, end_time + 90 * day))

    cost_before, credit_before = described_class.new(begin_time, end_time).run.first.content.values_at("cost", "credit")
    p1.update(credit: 10)
    cost_after, credit_after = described_class.new(begin_time, end_time, save_result: true).run.first.content.values_at("cost", "credit")

    expect(cost_after).to eq((cost_before - 10).round(3))
    expect(credit_before).to eq(0)
    expect(credit_after).to eq(10)
    expect(p1.reload.credit).to eq(0)
  end

  it "handles discounts and credits at the same time" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, end_time + 90 * day))

    before = described_class.new(begin_time, end_time).run.first.content
    p1.update(credit: 10, discount: 10)
    after = described_class.new(begin_time, end_time, save_result: true).run.first.content

    expect(after["cost"]).to eq((before["cost"] * 0.9 - 10).round(3))
    expect(after["discount"]).to eq((before["cost"] * 0.1).round(3))
    expect(after["credit"]).to eq(10)
    expect(p1.reload.credit).to eq(0)
  end

  it "handles github runner credit only" do
    github_runner = GithubRunner.create_with_id(label: "ubicloud", repository_name: "my-repo")
    generate_billing_record(p1, github_runner, Sequel::Postgres::PGRange.new(begin_time - 90 * day, end_time + 90 * day))

    invoice = described_class.new(begin_time, end_time).run.first.content

    expect(invoice["cost"]).to eq(invoice["subtotal"] - 1)
    expect(invoice["credit"]).to eq(1)
    expect(p1.reload.credit).to eq(0)
  end

  it "handles project and github runner credits together" do
    github_runner = GithubRunner.create_with_id(label: "ubicloud", repository_name: "my-repo")
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, end_time + 90 * day))
    generate_billing_record(p1, github_runner, Sequel::Postgres::PGRange.new(begin_time - 90 * day, end_time + 90 * day))

    before = described_class.new(begin_time, end_time).run.first.content
    p1.update(credit: 10, discount: 10)
    after = described_class.new(begin_time, end_time, save_result: true).run.first.content

    expect(before["cost"]).to eq(before["subtotal"] - 1)
    expect(after["cost"]).to eq((before["subtotal"] * 0.9 - 11).round(3))
    expect(after["discount"]).to eq((before["subtotal"] * 0.1).round(3))
    expect(after["credit"]).to eq(11)
    expect(p1.reload.credit).to eq(0)
  end

  it "handles full discount and github runner credits together" do
    github_runner = GithubRunner.create_with_id(label: "ubicloud", repository_name: "my-repo")
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, end_time + 90 * day))
    generate_billing_record(p1, github_runner, Sequel::Postgres::PGRange.new(begin_time - 90 * day, end_time + 90 * day))

    p1.update(credit: 0, discount: 100)
    invoice = described_class.new(begin_time, end_time, save_result: true).run.first.content

    expect(invoice["cost"]).to eq(0)
  end
end

# rubocop:enable RSpec/NoExpectationExample
