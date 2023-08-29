# frozen_string_literal: true

# rubocop:disable RSpec/NoExpectationExample
RSpec.describe InvoiceGenerator do
  def generate_vm_billing_record(project, vm, span)
    BillingRecord.create_with_id(
      project_id: project.id,
      resource_id: vm.id,
      resource_name: vm.name,
      span: span,
      billing_rate_id: BillingRate.from_resource_properties("VmCores", vm.family, vm.location)["id"],
      amount: vm.cores
    )
  end

  def check_invoice_for_single_vm(invoices, project, vm, duration)
    expect(invoices.count).to eq(1)

    br = BillingRate.from_resource_properties("VmCores", vm.family, vm.location)
    cost = vm.cores * [672 * 60, (duration / 60)].min * br["unit_price"]
    expect(invoices.first).to eq({
      project_id: project.id,
      project_name: project.name,
      resources: [{
        resource_id: vm.id,
        resource_name: vm.name,
        line_items: [{
          location: br["location"],
          resource_type: "VmCores",
          resource_family: vm.family,
          amount: vm.cores,
          cost: cost
        }],
        cost: cost
      }],
      cost: cost
    })
  end

  let(:p1) {
    Account.create_with_id(email: "auth1@example.com")
    Project.create_with_id(name: "cool-project", provider: "hetzner")
  }
  let(:vm1) { Vm.create_with_id(unix_user: "x", public_key: "x", name: "vm-1", family: "standard", cores: 2, location: "hetzner-hel1", boot_image: "x") }

  let(:day) { 24 * 60 * 60 }
  let(:begin_time) { Time.parse("2023-06-01") }
  let(:end_time) { Time.parse("2023-07-01") }

  it "does not generate invoice for billing record that started and terminated before this billing window" do
    generate_vm_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 150 * day, begin_time - 90 * day))
    invoices = described_class.new(begin_time, end_time).run
    expect(invoices.count).to eq(0)
  end

  it "generates invoice for billing record started before this billing window and not terminated yet" do
    generate_vm_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, nil))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 30 * day)
  end

  it "generates invoice for billing record started before this billing window and terminated in the future" do
    generate_vm_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, end_time + 90 * day))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 30 * day)
  end

  it "generates invoice for billing record started before this billing window and terminated before end of it" do
    generate_vm_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, begin_time + 15 * day))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 15 * day)
  end

  it "generates invoice for billing record started in this billing window and not terminated yet" do
    generate_vm_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time + 5 * day, nil))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 25 * day)
  end

  it "generates invoice for billing record started in this billing window and terminated in the future" do
    generate_vm_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time + 5 * day, end_time + 90 * day))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 25 * day)
  end

  it "generates invoice for billing record started in this billing window and terminated before end of it" do
    generate_vm_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time + 5 * day, begin_time + 15 * day))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 10 * day)
  end

  it "does not generate invoice for billing record started in a future billing window" do
    generate_vm_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(end_time + 5 * day, end_time + 15 * day))
    invoices = described_class.new(begin_time, end_time).run
    expect(invoices.count).to eq(0)
  end

  it "creates invoice record in the database only if save_result is set" do
    generate_vm_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, nil))
    described_class.new(begin_time, end_time, false).run
    expect(Invoice.count).to eq(0)

    described_class.new(begin_time, end_time, true).run
    expect(Invoice.count).to eq(1)

    expect(Invoice.first.invoice_number).to eq("#{begin_time.strftime("%y%m")}-#{p1.id[-10..]}-0001")
  end
end

# rubocop:enable RSpec/NoExpectationExample
