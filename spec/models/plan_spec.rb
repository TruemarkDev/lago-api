# frozen_string_literal: true

require "rails_helper"

RSpec.describe Plan, type: :model do
  subject(:plan) { build(:plan, trial_period: 3) }

  it { expect(described_class).to be_soft_deletable }

  it do
    expect(subject).to have_one(:minimum_commitment)
    expect(subject).to have_many(:usage_thresholds)
    expect(subject).to have_many(:commitments)
    expect(subject).to have_many(:charges).dependent(:destroy)
    expect(subject).to have_many(:billable_metrics).through(:charges)
    expect(subject).to have_many(:subscriptions)
    expect(subject).to have_many(:customers).through(:subscriptions)
    expect(subject).to have_many(:children).class_name("Plan").dependent(:destroy)
    expect(subject).to have_many(:coupon_targets)
    expect(subject).to have_many(:coupons).through(:coupon_targets)
    expect(subject).to have_many(:invoices).through(:subscriptions)
    expect(subject).to have_many(:usage_thresholds)
    expect(subject).to have_many(:applied_taxes).class_name("Plan::AppliedTax").dependent(:destroy)
    expect(subject).to have_many(:taxes).through(:applied_taxes)
    expect(subject).to have_many(:entitlements).class_name("Entitlement::Entitlement").dependent(:destroy)
    expect(subject).to have_many(:entitlement_values).through(:entitlements).source(:values).class_name("Entitlement::EntitlementValue").dependent(:destroy)

    expect(subject).to validate_presence_of(:interval)
    expect(subject).to define_enum_for(:interval).with_values(Plan::INTERVALS)
  end

  describe "Clickhouse associations", clickhouse: true do
    it { is_expected.to have_many(:activity_logs).class_name("Clickhouse::ActivityLog") }
  end

  it_behaves_like "paper_trail traceable"

  describe "Validations" do
    it "requires the pay_in_advance" do
      plan.pay_in_advance = nil
      expect(plan).not_to be_valid

      plan.pay_in_advance = true
      expect(plan).to be_valid
    end
  end

  describe "#has_trial?" do
    it "returns true when trial_period" do
      expect(plan).to have_trial
    end

    context "when value is 0" do
      let(:plan) { build(:plan, trial_period: 0) }

      it "returns false" do
        expect(plan).not_to have_trial
      end
    end
  end

  describe "#yearly_amount_cents" do
    let(:plan) do
      build(:plan, interval: :yearly, amount_cents: 100)
    end

    it { expect(plan.yearly_amount_cents).to eq(100) }

    context "when plan is monthly" do
      before { plan.interval = "monthly" }

      it { expect(plan.yearly_amount_cents).to eq(1200) }
    end

    context "when plan is weekly" do
      before { plan.interval = "weekly" }

      it { expect(plan.yearly_amount_cents).to eq(5200) }
    end

    context "when plan is quarterly" do
      before { plan.interval = "quarterly" }

      it { expect(plan.yearly_amount_cents).to eq(400) }
    end
  end

  describe "#invoice_name" do
    subject(:plan_invoice_name) { plan.invoice_name }

    context "when invoice display name is blank" do
      let(:plan) { build_stubbed(:plan, invoice_display_name: [nil, ""].sample) }

      it "returns name" do
        expect(plan_invoice_name).to eq(plan.name)
      end
    end

    context "when invoice display name is present" do
      let(:plan) { build_stubbed(:plan) }

      it "returns invoice display name" do
        expect(plan_invoice_name).to eq(plan.invoice_display_name)
      end
    end
  end

  describe "#active_subscriptions_count" do
    let(:plan) { create(:plan) }

    it "returns the number of active subscriptions" do
      create(:subscription, plan:)
      overridden_plan = create(:plan, parent_id: plan.id)
      create(:subscription, plan: overridden_plan)

      expect(plan.active_subscriptions_count).to eq(2)
    end
  end

  describe "#customers_count" do
    let(:customer) { create(:customer) }
    let(:plan) { create(:plan) }

    it "returns the number of impacted customers" do
      create(:subscription, customer:, plan:)
      overridden_plan = create(:plan, parent_id: plan.id)
      customer2 = create(:customer, organization: plan.organization)
      create(:subscription, customer: customer2, plan: overridden_plan)

      expect(plan.customers_count).to eq(2)
    end
  end

  describe "#draft_invoices_count" do
    let(:plan) { create(:plan) }

    it "returns the number draft invoices" do
      subscription = create(:subscription, plan:)
      invoice = create(:invoice, :draft)
      create(:invoice_subscription, invoice:, subscription:)

      overridden_plan = create(:plan, parent_id: plan.id)
      subscription2 = create(:subscription, plan: overridden_plan)
      invoice2 = create(:invoice, :draft)
      create(:invoice_subscription, invoice: invoice2, subscription: subscription2)

      expect(plan.draft_invoices_count).to eq(2)
    end
  end

  describe "#pay_in_arrears?" do
    context "when pay_in_advance is true" do
      let(:plan) { build(:plan, :pay_in_advance) }

      it { expect(plan.pay_in_arrears?).to be(false) }
    end

    context "when pay_in_advance is false" do
      let(:plan) { build(:plan) }

      it { expect(plan.pay_in_arrears?).to be(true) }
    end
  end
end
