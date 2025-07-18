# frozen_string_literal: true

class Invoice < ApplicationRecord
  self.ignored_columns += [:negative_amount_cents] # TODO: remove when negative_amount_cents is removed from the database

  include AASM
  include PaperTrailTraceable
  include Sequenced
  include RansackUuidSearch

  CREDIT_NOTES_MIN_VERSION = 2
  COUPON_BEFORE_VAT_VERSION = 3
  TAX_INVOICE_LABEL_COUNTRIES = %w[AU AE NZ ID SG].freeze

  # before_save :ensure_organization_sequential_id, if: -> { organization.per_organization? && !self_billed }
  before_save :ensure_billing_entity_sequential_id, if: -> { billing_entity&.per_billing_entity? && !self_billed? }
  before_save :ensure_number
  before_save :set_finalized_at, if: -> { status_changed_to_finalized? }

  belongs_to :customer, -> { with_discarded }
  belongs_to :organization
  belongs_to :billing_entity, optional: true

  has_many :fees
  has_many :credits
  has_many :wallet_transactions
  has_many :invoice_subscriptions
  has_many :subscriptions, through: :invoice_subscriptions
  has_many :plans, through: :subscriptions
  has_many :metadata, class_name: "Metadata::InvoiceMetadata", dependent: :destroy
  has_many :credit_notes
  has_many :progressive_billing_credits, class_name: "Credit", foreign_key: :progressive_billing_invoice_id

  has_many :applied_taxes, class_name: "Invoice::AppliedTax", dependent: :destroy
  has_many :taxes, through: :applied_taxes
  has_many :integration_resources, as: :syncable
  has_many :error_details, as: :owner, dependent: :destroy

  has_many :applied_payment_requests, class_name: "PaymentRequest::AppliedInvoice"
  has_many :payment_requests, through: :applied_payment_requests
  has_many :payments, as: :payable
  has_many :payment_receipts, through: :payments

  has_many :applied_usage_thresholds
  has_many :usage_thresholds, through: :applied_usage_thresholds
  has_many :applied_invoice_custom_sections

  has_many :activity_logs,
    -> { order(logged_at: :desc) },
    class_name: "Clickhouse::ActivityLog",
    as: :resource

  has_one_attached :file

  monetize :coupons_amount_cents,
    :credit_notes_amount_cents,
    :fees_amount_cents,
    :prepaid_credit_amount_cents,
    :progressive_billing_credit_amount_cents,
    :sub_total_excluding_taxes_amount_cents,
    :sub_total_including_taxes_amount_cents,
    :total_amount_cents,
    :total_paid_amount_cents,
    :taxes_amount_cents,
    with_model_currency: :currency

  # NOTE: Readonly fields
  monetize :charge_amount_cents,
    :subscription_amount_cents,
    :total_due_amount_cents,
    disable_validation: true,
    allow_nil: true,
    with_model_currency: :currency

  INVOICE_TYPES = %i[subscription add_on credit one_off advance_charges progressive_billing].freeze
  PAYMENT_STATUS = %i[pending succeeded failed].freeze
  TAX_STATUSES = {
    pending: "pending",
    succeeded: "succeeded",
    failed: "failed"
  }.freeze

  VISIBLE_STATUS = {draft: 0, finalized: 1, voided: 2, failed: 4, pending: 7}.freeze
  INVISIBLE_STATUS = {generating: 3, open: 5, closed: 6}.freeze
  STATUS = VISIBLE_STATUS.merge(INVISIBLE_STATUS).freeze
  GENERATED_INVOICE_STATUSES = %w[finalized closed].freeze

  enum :invoice_type, INVOICE_TYPES
  enum :payment_status, PAYMENT_STATUS, prefix: :payment
  enum :status, STATUS

  attribute :tax_status, :string
  enum :tax_status, TAX_STATUSES, prefix: :tax

  aasm column: "status", timestamps: true do
    state :generating
    state :draft
    state :open
    state :finalized
    state :voided
    state :failed
    state :closed
    state :pending

    event :finalize do
      transitions from: :draft, to: :finalized
    end

    event :void do
      transitions from: :finalized, to: :voided, after: :handle_void_transition!
    end
  end

  sequenced scope: ->(invoice) { invoice.customer.invoices },
    lock_key: ->(invoice) { invoice.customer_id }

  scope :visible, -> { where(status: VISIBLE_STATUS.keys) }
  scope :invisible, -> { where(status: INVISIBLE_STATUS.keys) }
  scope :with_generated_number, -> { where(status: %w[finalized voided]) }
  scope :ready_to_be_refreshed, -> { draft.where(ready_to_be_refreshed: true) }
  scope :ready_to_be_finalized, -> { draft.where("issuing_date <= ?", Time.current.to_date) }

  scope :created_before,
    lambda { |invoice|
      where.not(id: invoice.id)
        .where("invoices.created_at < ?", invoice.created_at)
    }

  scope :payment_overdue, -> { where(payment_overdue: true) }

  scope :with_active_subscriptions, -> {
    joins(:subscriptions)
      .where(subscriptions: {status: "active"})
      .distinct
  }

  scope :self_billed, -> { where(self_billed: true) }
  scope :non_self_billed, -> { where(self_billed: false) }

  validates :issuing_date, :currency, presence: true
  validates :timezone, timezone: true, allow_nil: true
  validates :total_amount_cents, numericality: {greater_than_or_equal_to: 0}
  validates :payment_dispute_lost_at, absence: true, unless: :payment_dispute_losable?

  def self.ransackable_attributes(_ = nil)
    %w[id number]
  end

  def self.ransackable_associations(_ = nil)
    %w[customer]
  end

  def payment_invoices
    Invoice.where(id: id)
  end

  def visible?
    !invisible?
  end

  def invisible?
    INVISIBLE_STATUS.key?(status.to_sym)
  end

  def file_url
    return if file.blank?

    blob_path = Rails.application.routes.url_helpers.rails_blob_path(
      file,
      host: "void"
    )

    File.join(ENV["LAGO_API_URL"], blob_path)
  end

  def fee_total_amount_cents
    amount_cents = fees.sum(:amount_cents)
    taxes_amount_cents = fees.sum { |f| f.amount_cents * f.taxes_rate }.fdiv(100).round
    amount_cents + taxes_amount_cents
  end

  def charge_amount_cents
    fees.charge.sum(:amount_cents)
  end

  def subscription_amount_cents
    fees.subscription.sum(:amount_cents)
  end

  def invoice_subscription(subscription_id)
    invoice_subscriptions.find_by(subscription_id:)
  end

  def subscription_fees(subscription_id)
    invoice_subscription(subscription_id).fees
  end

  def progressive_billing_credits_for_subscription(subscription)
    credits.where(
      progressive_billing_invoice_id: subscription.invoices.progressive_billing.select(:id)
    )
  end

  def existing_fees_in_interval?(subscription_id:, charge_in_advance: false)
    subscription_fees(subscription_id)
      .charge
      .positive_units
      .where(true_up_parent_fee: nil)
      .joins(:charge)
      .where(charge: {pay_in_advance: charge_in_advance})
      .any?
  end

  def recurring_fees(subscription_id)
    subscription_fees(subscription_id)
      .joins(charge: :billable_metric)
      .where(billable_metric: {recurring: true})
      .where(billable_metric: {aggregation_type: %i[sum_agg unique_count_agg]})
      .where(charge: {pay_in_advance: false})
  end

  def recurring_breakdown(fee)
    service = case fee.charge.billable_metric.aggregation_type.to_sym
    when :sum_agg
      BillableMetrics::Breakdown::SumService
    when :unique_count_agg
      BillableMetrics::Breakdown::UniqueCountService
    else
      raise(NotImplementedError)
    end

    filters = {}
    if fee.charge_filter
      result = ChargeFilters::MatchingAndIgnoredService.call(charge: fee.charge, filter: fee.charge_filter)
      filters[:charge_filter] = fee.charge_filter if fee.charge_filter
      filters[:matching_filters] = result.matching_filters
      filters[:ignored_filters] = result.ignored_filters
    end

    service.new(
      event_store_class: Events::Stores::PostgresStore,
      charge: fee.charge,
      subscription: fee.subscription,
      boundaries: {
        from_datetime: Time.zone.parse(fee.properties["charges_from_datetime"]),
        to_datetime: Time.zone.parse(fee.properties["charges_to_datetime"]),
        charges_duration: fee.properties["charges_duration"]
      },
      filters:
    ).breakdown.breakdown
  end

  def charge_pay_in_advance_proration_range(fee, timestamp)
    date_service = Subscriptions::DatesService.new_instance(
      fee.subscription,
      Time.zone.at(timestamp),
      current_usage: true
    )

    event = Event.find_by(id: fee.pay_in_advance_event_id)

    return {} unless event

    number_of_days = Utils::Datetime.date_diff_with_timezone(
      event.timestamp,
      date_service.charges_to_datetime,
      customer.applicable_timezone
    )

    {
      number_of_days:,
      period_duration: date_service.charges_duration_in_days
    }
  end

  def total_due_amount_cents
    total_amount_cents - total_paid_amount_cents
  end

  # amount cents onto which we can issue a credit note
  def available_to_credit_amount_cents
    return 0 if version_number < CREDIT_NOTES_MIN_VERSION || draft?

    fees_total_creditable = fees.sum(&:creditable_amount_cents)
    return 0 if fees_total_creditable.zero?

    credit_adjustement = if version_number < Invoice::COUPON_BEFORE_VAT_VERSION
      0
    else
      (coupons_amount_cents + progressive_billing_credit_amount_cents).fdiv(fees_amount_cents) * fees_total_creditable
    end

    vat = fees.sum do |fee|
      # NOTE: Because coupons are applied before VAT,
      #       we have to discribute the coupon adjustement at prorata of each fees
      #       to compute the VAT
      fee_rate = fee.creditable_amount_cents.fdiv(fees_total_creditable)
      prorated_credit_amount = credit_adjustement * fee_rate
      (fee.creditable_amount_cents - prorated_credit_amount) * (fee.taxes_rate || 0)
    end.fdiv(100).round # BECAUSE OF THIS ROUND the returned value is not precise

    fees_total_creditable - credit_adjustement + vat
  end

  # amount cents onto which we can issue a credit note as credit
  def creditable_amount_cents
    return 0 if credit?
    available_to_credit_amount_cents
  end

  # amount cents onto which we can issue a credit note as refund
  def refundable_amount_cents
    return 0 if version_number < CREDIT_NOTES_MIN_VERSION || draft?
    return 0 if !payment_succeeded? && total_paid_amount_cents == total_amount_cents

    amount = total_paid_amount_cents - credit_notes.sum("refund_amount_cents + credit_amount_cents")
    amount = amount.negative? ? 0 : amount

    return [amount, associated_active_wallet&.balance_cents || 0].min if credit?
    amount
  end

  def associated_active_wallet
    return if !credit? || customer.wallets.active.empty?

    wallet = fees.credit.first&.invoiceable&.wallet
    wallet if wallet&.active?
  end

  def payment_dispute_losable?
    finalized?
  end

  def voidable?
    if payment_dispute_lost_at? || total_paid_amount_cents > 0 || credit_notes.where.not(credit_status: :voided).any?
      return false
    end

    finalized? && (payment_pending? || payment_failed?)
  end

  def all_charges_have_fees?
    return true unless subscription?

    subscriptions.includes(plan: {charges: :filters}).all? do |subscription|
      subscription.plan.charges.all? do |charge|
        charge_fee_exists = fees.charge.any? { |f| f.charge_id == charge.id && f.charge_filter_id.nil? }
        next charge_fee_exists if charge.filters.empty?

        charge_fee_exists && charge.filters.all? do |fi|
          fees.charge.any? { |f| f.charge_id == charge.id && f.charge_filter_id == fi.id }
        end
      end
    end
  end

  def different_boundaries_for_subscription_and_charges(subscription)
    subscription_from = invoice_subscription(subscription.id).from_datetime_in_customer_timezone&.to_date
    subscription_to = invoice_subscription(subscription.id).to_datetime_in_customer_timezone&.to_date
    charges_from = invoice_subscription(subscription.id).charges_from_datetime_in_customer_timezone&.to_date
    charges_to = invoice_subscription(subscription.id).charges_to_datetime_in_customer_timezone&.to_date

    subscription_from != charges_from && subscription_to != charges_to
  end

  def mark_as_dispute_lost!(timestamp = Time.current)
    self.payment_dispute_lost_at ||= timestamp
    self.payment_overdue = false
    save!
  end

  def should_sync_invoice?
    !self_billed && finalized? && customer.integration_customers.accounting_kind.any? { |c| c.integration.sync_invoices }
  end

  def should_sync_hubspot_invoice?
    finalized? && should_update_hubspot_invoice?
  end

  def should_sync_salesforce_invoice?
    !self_billed && finalized? && customer.integration_customers.salesforce_kind.any?
  end

  def should_update_hubspot_invoice?
    !self_billed && customer.integration_customers.hubspot_kind.any? { |c| c.integration.sync_invoices }
  end

  def document_invoice_name
    return I18n.t("invoice.self_billed.document_name") if self_billed?
    return I18n.t("invoice.prepaid_credit_invoice") if credit?

    if TAX_INVOICE_LABEL_COUNTRIES.include?(organization.country)
      return I18n.t("invoice.paid_tax_invoice") if advance_charges?
      return I18n.t("invoice.document_tax_name")
    end

    return I18n.t("invoice.paid_invoice") if advance_charges?

    I18n.t("invoice.document_name")
  end

  def should_apply_provider_tax?
    should_finalize_invoice = Invoices::TransitionToFinalStatusService.new(invoice: self).should_finalize_invoice?

    fees.any? && should_finalize_invoice
  end

  private

  def should_assign_sequential_id?
    status_changed_to_finalized?
  end

  def handle_void_transition!
    update!(
      ready_for_payment_processing: false,
      voided_at: Time.current
    )
  end

  def ensure_number
    self.number = "#{billing_entity.document_number_prefix}-DRAFT" if number.blank? && !status_changed_to_finalized?

    return unless status_changed_to_finalized?

    if billing_entity.per_customer? || self_billed
      # NOTE: Example of expected customer slug format is ORG_PREFIX-005
      customer_slug = "#{billing_entity.document_number_prefix}-#{format("%03d", customer.sequential_id)}"
      formatted_sequential_id = format("%03d", sequential_id)

      self.number = "#{customer_slug}-#{formatted_sequential_id}"
    else
      billing_entity_formatted_sequential_id = format("%03d", billing_entity_sequential_id)
      formatted_year_and_month = Time.now.in_time_zone(billing_entity.timezone || "UTC").strftime("%Y%m")

      self.number = "#{billing_entity.document_number_prefix}-#{formatted_year_and_month}-#{billing_entity_formatted_sequential_id}"
    end
  end

  def ensure_billing_entity_sequential_id
    return if self_billed?
    return if billing_entity_sequential_id

    # NOTE: this should actually be run by the state machine, however,
    #       we are not using it and status is changed without calling the state machine event
    return unless status_changed_to_finalized?

    self.billing_entity_sequential_id = generate_billing_entity_sequential_id
  end

  def generate_billing_entity_sequential_id
    # Use advisory lock to ensure only one process can generate IDs for this billing entity at a time
    lock_key = "billing_entity_sequential_id_#{billing_entity_id}"

    result = Invoice.with_advisory_lock(lock_key, transaction: true, timeout_seconds: 10.seconds) do
      billing_entity_sequential_id = billing_entity
        .invoices
        .non_self_billed
        .with_generated_number
        .maximum(:billing_entity_sequential_id) || 0

      loop do
        billing_entity_sequential_id += 1
        break billing_entity_sequential_id unless billing_entity.invoices.non_self_billed.with_generated_number.exists?(billing_entity_sequential_id:)
      end
    end

    # NOTE: If the application was unable to acquire the lock, the block returns false
    raise(SequenceError, "Unable to acquire lock on the database") unless result

    result
  end

  def ensure_organization_sequential_id
    return if organization_sequential_id.present? && organization_sequential_id.positive?
    return unless status_changed_to_finalized?

    self.organization_sequential_id = generate_organization_sequential_id
    self.billing_entity_sequential_id = organization_sequential_id
  end

  def generate_organization_sequential_id
    timezone = organization.timezone || "UTC"
    organization_sequence_scope = organization.invoices.with_generated_number.where(
      "date_trunc('month', created_at::timestamptz AT TIME ZONE ?)::date = ?",
      timezone,
      Time.now.in_time_zone(timezone).beginning_of_month.to_date
    ).non_self_billed

    result = Invoice.with_advisory_lock(
      organization_id,
      transaction: true,
      timeout_seconds: 10.seconds
    ) do
      organization_sequential_id = organization
        .invoices
        .non_self_billed
        .maximum(:organization_sequential_id) || 0

      # NOTE: Start with the most recent sequential id and find first available sequential id that haven't occurred
      loop do
        organization_sequential_id += 1

        break organization_sequential_id unless organization_sequence_scope.exists?(organization_sequential_id:)
      end
    end

    # NOTE: If the application was unable to acquire the lock, the block returns false
    raise(SequenceError, "Unable to acquire lock on the database") unless result

    result
  end

  def status_changed_to_finalized?
    status_changed?(from: "draft", to: "finalized") ||
      status_changed?(from: "generating", to: "finalized") ||
      status_changed?(from: "open", to: "finalized") ||
      status_changed?(from: "failed", to: "finalized") ||
      status_changed?(from: "pending", to: "finalized")
  end

  def set_finalized_at
    return unless status_changed_to_finalized?

    self.finalized_at ||= Time.current
  end
end

# == Schema Information
#
# Table name: invoices
#
#  id                                      :uuid             not null, primary key
#  applied_grace_period                    :integer
#  coupons_amount_cents                    :bigint           default(0), not null
#  credit_notes_amount_cents               :bigint           default(0), not null
#  currency                                :string
#  fees_amount_cents                       :bigint           default(0), not null
#  file                                    :string
#  finalized_at                            :datetime
#  invoice_type                            :integer          default("subscription"), not null
#  issuing_date                            :date
#  net_payment_term                        :integer          default(0), not null
#  number                                  :string           default(""), not null
#  payment_attempts                        :integer          default(0), not null
#  payment_dispute_lost_at                 :datetime
#  payment_due_date                        :date
#  payment_overdue                         :boolean          default(FALSE)
#  payment_status                          :integer          default("pending"), not null
#  prepaid_credit_amount_cents             :bigint           default(0), not null
#  progressive_billing_credit_amount_cents :bigint           default(0), not null
#  ready_for_payment_processing            :boolean          default(TRUE), not null
#  ready_to_be_refreshed                   :boolean          default(FALSE), not null
#  self_billed                             :boolean          default(FALSE), not null
#  skip_charges                            :boolean          default(FALSE), not null
#  status                                  :integer          default("finalized"), not null
#  sub_total_excluding_taxes_amount_cents  :bigint           default(0), not null
#  sub_total_including_taxes_amount_cents  :bigint           default(0), not null
#  tax_status                              :enum
#  taxes_amount_cents                      :bigint           default(0), not null
#  taxes_rate                              :float            default(0.0), not null
#  timezone                                :string           default("UTC"), not null
#  total_amount_cents                      :bigint           default(0), not null
#  total_paid_amount_cents                 :bigint           default(0), not null
#  version_number                          :integer          default(4), not null
#  voided_at                               :datetime
#  created_at                              :datetime         not null
#  updated_at                              :datetime         not null
#  billing_entity_id                       :uuid             not null
#  billing_entity_sequential_id            :integer
#  customer_id                             :uuid
#  organization_id                         :uuid             not null
#  organization_sequential_id              :integer          default(0), not null
#  sequential_id                           :integer
#  voided_invoice_id                       :uuid
#
# Indexes
#
#  idx_on_billing_entity_id_billing_entity_sequential__bd26b2e655  (billing_entity_id,billing_entity_sequential_id DESC)
#  idx_on_organization_id_organization_sequential_id_2387146f54    (organization_id,organization_sequential_id DESC)
#  index_invoices_on_billing_entity_id                             (billing_entity_id)
#  index_invoices_on_customer_id                                   (customer_id)
#  index_invoices_on_customer_id_and_sequential_id                 (customer_id,sequential_id) UNIQUE
#  index_invoices_on_issuing_date                                  (issuing_date)
#  index_invoices_on_number                                        (number)
#  index_invoices_on_organization_id                               (organization_id)
#  index_invoices_on_payment_overdue                               (payment_overdue)
#  index_invoices_on_ready_to_be_refreshed                         (ready_to_be_refreshed) WHERE (ready_to_be_refreshed = true)
#  index_invoices_on_self_billed                                   (self_billed)
#  index_invoices_on_sequential_id                                 (sequential_id)
#  index_invoices_on_status                                        (status)
#  index_invoices_on_voided_invoice_id                             (voided_invoice_id)
#
# Foreign Keys
#
#  fk_rails_...  (billing_entity_id => billing_entities.id)
#  fk_rails_...  (customer_id => customers.id)
#  fk_rails_...  (organization_id => organizations.id)
#
