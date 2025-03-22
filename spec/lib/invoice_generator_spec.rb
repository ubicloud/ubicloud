# frozen_string_literal: true

# rubocop:disable RSpec/NoExpectationExample
RSpec.describe InvoiceGenerator do
  def generate_billing_record(project, resource, span, amount = 5000)
    case resource
    when Vm
      vm = resource
      billing_rate_id = BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"]
      amount = vm.vcpus
      name = vm.name
    when GithubRunner
      gr = resource
      billing_rate_id = BillingRate.from_resource_properties("GitHubRunnerMinutes", gr.label_data["vm_size"], "global")["id"]
      name = "foo"
    when InferenceEndpoint
      billing_rate_id = BillingRate.from_resource_properties("InferenceTokens", resource.model_name, "global")["id"]
      name = resource.name
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

  def check_invoice_for_single_vm(invoices, project, vm, duration, begin_time, expected_vat_info: nil)
    expect(invoices.count).to eq(1)
    expected_issuer = if expected_vat_info
      {
        "name" => "Ubicloud B.V.",
        "address" => "Turfschip 267",
        "country" => "NL",
        "city" => "Amstelveen",
        "postal_code" => "1186 XK",
        "tax_id" => "NL864651442B01",
        "trade_id" => "88492729",
        "in_eu_vat" => true
      }
    else
      {
        "name" => "Ubicloud Inc.",
        "address" => "310 Santa Ana Avenue",
        "country" => "US",
        "city" => "San Francisco",
        "state" => "CA",
        "postal_code" => "94127"
      }
    end

    expected_billing_info = project.billing_info&.stripe_data&.merge({
      "id" => project.billing_info.id,
      "ubid" => project.billing_info.ubid,
      "in_eu_vat" => !!expected_vat_info
    })

    br = BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)
    duration_mins = [672 * 60, (duration / 60).ceil].min
    expected_cost = (vm.vcpus * duration_mins * br["unit_price"]).round(3)
    expected_resources = [{
      "resource_id" => vm.id,
      "resource_name" => vm.name,
      "line_items" => [{
        "location" => br["location"],
        "resource_type" => "VmVCpu",
        "resource_family" => vm.family,
        "description" => "standard-#{vm.vcpus} Virtual Machine",
        "amount" => vm.vcpus.to_f,
        "duration" => duration_mins,
        "cost" => expected_cost,
        "begin_time" => begin_time.utc.to_s,
        "unit_price" => br["unit_price"]
      }],
      "cost" => expected_cost
    }]
    actual_content = invoices.first.content
    [
      ["project_id", project.id],
      ["project_name", project.name],
      ["billing_info", expected_billing_info],
      ["issuer_info", expected_issuer],
      ["vat_info", expected_vat_info],
      ["resources", expected_resources],
      ["subtotal", expected_cost],
      ["discount", 0],
      ["credit", 0],
      ["cost", (expected_cost + expected_vat_info&.fetch("amount", 0).to_f).round(3)]
    ].each do |key, expected|
      expect(actual_content[key]).to eq(expected)
    end
  end

  let(:p1) {
    Account.create_with_id(email: "auth1@example.com")
    Project.create_with_id(name: "cool-project")
  }
  let(:vm1) { create_vm }
  let(:ps) { Prog::Vnet::SubnetNexus.assemble(p1.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject }
  let(:lb) { Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "dummy-lb-1", src_port: 80, dst_port: 80, health_check_endpoint: "/up") }
  let(:ie1) { InferenceEndpoint.create_with_id(name: "ie1", model_name: "test-model", project_id: p1.id, is_public: true, visible: true, location_id: Location::HETZNER_FSN1_ID, vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, load_balancer_id: lb.id) }

  let(:day) { 24 * 60 * 60 }
  let(:begin_time) { Time.utc(2023, 6) }
  let(:end_time) { Time.utc(2023, 7) }

  it "fails if eur_rate not provided while saving result" do
    expect { described_class.new(begin_time, end_time, save_result: true).run }.to raise_error(ArgumentError, "eur_rate must be provided when save_result is true")
  end

  it "does not generate invoice for billing record that started and terminated before this billing window" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 150 * day, begin_time - 90 * day))
    invoices = described_class.new(begin_time, end_time).run
    expect(invoices.count).to eq(0)
  end

  it "generates invoice for billing record started before this billing window and not terminated yet" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, nil))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 30 * day, begin_time - 90 * day)
  end

  it "generates invoice for billing record started before this billing window and terminated in the future" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, end_time + 90 * day))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 30 * day, begin_time - 90 * day)
  end

  it "generates invoice for billing record started before this billing window and terminated before end of it" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, begin_time + 15 * day))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 15 * day, begin_time - 90 * day)
  end

  it "generates invoice for billing record started in this billing window and not terminated yet" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time + 5 * day, nil))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 25 * day, begin_time + 5 * day)
  end

  it "generates invoice for billing record started in this billing window and terminated in the future" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time + 5 * day, end_time + 90 * day))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 25 * day, begin_time + 5 * day)
  end

  it "generates invoice for billing record started in this billing window and terminated before end of it" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time + 5 * day, begin_time + 15 * day))
    invoices = described_class.new(begin_time, end_time).run
    check_invoice_for_single_vm(invoices, p1, vm1, 10 * day, begin_time + 5 * day)
  end

  it "does not generate invoice for billing record started in a future billing window" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(end_time + 5 * day, end_time + 15 * day))
    invoices = described_class.new(begin_time, end_time).run
    expect(invoices.count).to eq(0)
  end

  context "when project has billing info" do
    before do
      allow(Config).to receive(:stripe_secret_key).and_return("secret_key").at_least(:once)
    end

    it "charges no VAT for non-EU customer" do
      expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "metadata" => {"tax_id" => "123456"}, "address" => {"line1" => "123 Main St", "country" => "US"}}).at_least(:once)
      p1.update(billing_info_id: BillingInfo.create_with_id(stripe_id: "cs_1234567890").id)

      generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, nil))
      invoices = described_class.new(begin_time, end_time).run
      check_invoice_for_single_vm(invoices, p1, vm1, 30 * day, begin_time - 90 * day)
    end

    it "charges 21% VAT for Dutch customer with tax id" do
      expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "metadata" => {"tax_id" => "123456"}, "address" => {"line1" => "123 Main St", "country" => "NL"}}).at_least(:once)
      p1.update(billing_info_id: BillingInfo.create_with_id(stripe_id: "cs_1234567890").id)

      generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, nil))
      invoices = described_class.new(begin_time, end_time, eur_rate: 1.1).run
      check_invoice_for_single_vm(invoices, p1, vm1, 30 * day, begin_time - 90 * day, expected_vat_info: {"amount" => 5.166, "eur_rate" => 1.1, "rate" => 21, "reversed" => false})
    end

    it "charges 21% VAT for Dutch customer without tax id" do
      expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "metadata" => {}, "address" => {"line1" => "123 Main St", "country" => "NL"}}).at_least(:once)
      p1.update(billing_info_id: BillingInfo.create_with_id(stripe_id: "cs_1234567890").id)

      generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, nil))
      invoices = described_class.new(begin_time, end_time, eur_rate: 1.1).run
      check_invoice_for_single_vm(invoices, p1, vm1, 30 * day, begin_time - 90 * day, expected_vat_info: {"amount" => 5.166, "eur_rate" => 1.1, "rate" => 21, "reversed" => false})
    end

    it "reverse charges VAT for non-Dutch EU customer with tax id" do
      expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "metadata" => {"tax_id" => "123456"}, "address" => {"line1" => "123 Main St", "country" => "DE"}}).at_least(:once)
      p1.update(billing_info_id: BillingInfo.create_with_id(stripe_id: "cs_1234567890").id)

      generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, nil))
      invoices = described_class.new(begin_time, end_time).run
      check_invoice_for_single_vm(invoices, p1, vm1, 30 * day, begin_time - 90 * day, expected_vat_info: {"rate" => 0, "reversed" => true})
    end

    it "charges 21% VAT for non-Dutch EU customer without tax id until threshold" do
      expect(Config).to receive(:annual_non_dutch_eu_sales_exceed_threshold).and_return(false)
      expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "metadata" => {}, "address" => {"line1" => "123 Main St", "country" => "DE"}}).at_least(:once)
      p1.update(billing_info_id: BillingInfo.create_with_id(stripe_id: "cs_1234567890").id)

      generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, nil))
      invoices = described_class.new(begin_time, end_time, eur_rate: 1.1).run
      check_invoice_for_single_vm(invoices, p1, vm1, 30 * day, begin_time - 90 * day, expected_vat_info: {"amount" => 5.166, "eur_rate" => 1.1, "rate" => 21, "reversed" => false})
    end

    it "charges local VAT for non-Dutch EU customer without tax id if threshold exceeds" do
      expect(Config).to receive(:annual_non_dutch_eu_sales_exceed_threshold).and_return(true)
      expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "metadata" => {}, "address" => {"line1" => "123 Main St", "country" => "DE"}}).at_least(:once)
      p1.update(billing_info_id: BillingInfo.create_with_id(stripe_id: "cs_1234567890").id)

      generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, nil))
      invoices = described_class.new(begin_time, end_time, eur_rate: 1.1).run
      check_invoice_for_single_vm(invoices, p1, vm1, 30 * day, begin_time - 90 * day, expected_vat_info: {"amount" => 4.674, "eur_rate" => 1.1, "rate" => 19, "reversed" => false})
    end

    it "charges no VAT if the total is less than minimum invoice charge threshold" do
      expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "metadata" => {}, "address" => {"line1" => "123 Main St", "country" => "DE"}}).at_least(:once)
      p1.update(billing_info_id: BillingInfo.create_with_id(stripe_id: "cs_1234567890").id)

      generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time, begin_time + 0.5 * day), 2)
      invoices = described_class.new(begin_time, end_time).run
      expect(invoices.first.content["vat_info"]).to be_nil
    end

    it "charges no VAT if the address is missing" do
      expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "ACME Inc.", "metadata" => {}, "address" => nil}).at_least(:once)
      p1.update(billing_info_id: BillingInfo.create_with_id(stripe_id: "cs_1234567890").id)

      generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time, begin_time + 0.5 * day), 2)
      invoices = described_class.new(begin_time, end_time).run
      expect(invoices.first.content["vat_info"]).to be_nil
    end
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

    described_class.new(begin_time, end_time, save_result: true, eur_rate: 1.1).run
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
    cost_after, credit_after = described_class.new(begin_time, end_time, save_result: true, eur_rate: 1.1).run.first.content.values_at("cost", "credit")

    expect(cost_after).to eq((cost_before - 10).round(3))
    expect(credit_before).to eq(0)
    expect(credit_after).to eq(10)
    expect(p1.reload.credit).to eq(0)
  end

  it "handles discounts and credits at the same time" do
    generate_billing_record(p1, vm1, Sequel::Postgres::PGRange.new(begin_time - 90 * day, end_time + 90 * day))

    before = described_class.new(begin_time, end_time).run.first.content
    p1.update(credit: 10, discount: 10)
    after = described_class.new(begin_time, end_time, save_result: true, eur_rate: 1.1).run.first.content

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
    after = described_class.new(begin_time, end_time, save_result: true, eur_rate: 1.1).run.first.content

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
    invoice = described_class.new(begin_time, end_time, save_result: true, eur_rate: 1.1).run.first.content

    expect(invoice["cost"]).to eq(0)
  end

  it "handles inference quota when not used up" do
    generate_billing_record(p1, ie1, Sequel::Postgres::PGRange.new(begin_time.to_date.to_time, begin_time.to_date.to_time + day), 100000)
    invoice = described_class.new(begin_time, end_time, save_result: true, eur_rate: 1.1).run.first.content
    billing_rate = BillingRate.from_resource_properties("InferenceTokens", ie1.model_name, "global")["unit_price"]
    expect(invoice["free_inference_tokens_credit"]).to eq(100000 * billing_rate)
    expect(invoice["cost"]).to eq(0)
  end

  it "handles inference quota when used up" do
    generate_billing_record(p1, ie1, Sequel::Postgres::PGRange.new(begin_time.to_date.to_time + day, begin_time.to_date.to_time + 2 * day), 600000)
    invoice = described_class.new(begin_time, end_time, save_result: true, eur_rate: 1.1).run.first.content
    free_inference_tokens = FreeQuota.free_quotas["inference-tokens"]["value"]
    billing_rate = BillingRate.from_resource_properties("InferenceTokens", ie1.model_name, "global")["unit_price"]
    expect(free_inference_tokens).to eq(500000)
    expect(billing_rate).to eq(0.0000000500)
    expect(invoice["free_inference_tokens_credit"]).to eq(free_inference_tokens * billing_rate)
    expect(invoice["cost"]).to eq((600000 - free_inference_tokens) * billing_rate)
  end

  it "handles inference quota and project credit together" do
    generate_billing_record(p1, ie1, Sequel::Postgres::PGRange.new(begin_time.to_date.to_time + day, begin_time.to_date.to_time + 2 * day), 60000000)
    before = described_class.new(begin_time, end_time).run.first.content
    p1.update(credit: 1, discount: 10)
    after = described_class.new(begin_time, end_time, save_result: true, eur_rate: 1.1).run.first.content

    free_inference_tokens = FreeQuota.free_quotas["inference-tokens"]["value"]
    billing_rate = BillingRate.from_resource_properties("InferenceTokens", ie1.model_name, "global")["unit_price"]
    expect(before["free_inference_tokens_credit"]).to eq(free_inference_tokens * billing_rate)
    expect(before["discount"]).to eq(0)
    expect(before["credit"]).to eq(0)
    expect(before["cost"]).to eq(((60000000 - free_inference_tokens) * billing_rate).round(3))
    expect(after["free_inference_tokens_credit"]).to eq(free_inference_tokens * billing_rate)
    expect(after["discount"]).to eq((billing_rate * 60000000 * 0.1).round(3))
    expect(after["credit"]).to eq(1)
    expect(after["cost"]).to eq((60000000 * billing_rate * 0.9 - free_inference_tokens * billing_rate - 1).round(3))
    expect(p1.reload.credit).to eq(0)
  end

  it "handles inference quota with two different models on the same day" do
    ie2 = InferenceEndpoint.create_with_id(name: "ie2", model_name: "test-model2", project_id: p1.id, is_public: true, visible: true, location_id: Location::HETZNER_FSN1_ID, vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, load_balancer_id: lb.id)
    generate_billing_record(p1, ie1, Sequel::Postgres::PGRange.new(begin_time.to_date.to_time, begin_time.to_date.to_time + day), 100000)
    generate_billing_record(p1, ie2, Sequel::Postgres::PGRange.new(begin_time.to_date.to_time, begin_time.to_date.to_time + day), 800000)
    invoice = described_class.new(begin_time, end_time, save_result: true, eur_rate: 1.1).run.first.content
    free_inference_tokens = FreeQuota.free_quotas["inference-tokens"]["value"]
    billing_rate1 = BillingRate.from_resource_properties("InferenceTokens", ie1.model_name, "global")["unit_price"]
    billing_rate2 = BillingRate.from_resource_properties("InferenceTokens", ie2.model_name, "global")["unit_price"]
    expect(billing_rate1).to eq(0.0000000500)
    expect(billing_rate2).to eq(0.0000002000)
    expect(invoice["free_inference_tokens_credit"]).to eq(free_inference_tokens * billing_rate2)
    expect(invoice["cost"]).to eq((800000 - free_inference_tokens) * billing_rate2 + 100000 * billing_rate1)
    expect(invoice["resources"].count).to eq(2)
  end

  it "handles inference quota with two different models on different days" do
    ie2 = InferenceEndpoint.create_with_id(name: "ie2", model_name: "test-model2", project_id: p1.id, is_public: true, visible: true, location_id: Location::HETZNER_FSN1_ID, vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, load_balancer_id: lb.id)
    generate_billing_record(p1, ie1, Sequel::Postgres::PGRange.new(begin_time.to_date.to_time, begin_time.to_date.to_time + day), 100000)
    generate_billing_record(p1, ie2, Sequel::Postgres::PGRange.new(begin_time.to_date.to_time + 2 * day, begin_time.to_date.to_time + 3 * day), 800000)
    invoice = described_class.new(begin_time, end_time, save_result: true, eur_rate: 1.1).run.first.content
    free_inference_tokens = FreeQuota.free_quotas["inference-tokens"]["value"]
    billing_rate1 = BillingRate.from_resource_properties("InferenceTokens", ie1.model_name, "global")["unit_price"]
    billing_rate2 = BillingRate.from_resource_properties("InferenceTokens", ie2.model_name, "global")["unit_price"]
    expect(invoice["free_inference_tokens_credit"]).to eq(100000 * billing_rate1 + (free_inference_tokens - 100000) * billing_rate2)
    expect(invoice["cost"]).to eq((800000 - (free_inference_tokens - 100000)) * billing_rate2)
    expect(invoice["resources"].count).to eq(2)
  end
end

# rubocop:enable RSpec/NoExpectationExample
