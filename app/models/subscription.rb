# frozen_string_literal: true

class Subscription < ApplicationRecord
  include PaperTrailTraceable
  include RansackUuidSearch

  belongs_to :customer, -> { with_discarded }
  belongs_to :plan, -> { with_discarded }
  belongs_to :previous_subscription, class_name: "Subscription", optional: true
  belongs_to :organization

  has_one :billing_entity, through: :customer
  has_many :next_subscriptions, class_name: "Subscription", foreign_key: :previous_subscription_id
  has_many :events
  has_many :invoice_subscriptions
  has_many :invoices, through: :invoice_subscriptions
  has_many :integration_resources, as: :syncable
  has_many :fees
  has_many :daily_usages
  has_many :usage_thresholds, through: :plan

  has_many :activity_logs,
    -> { order(logged_at: :desc) },
    class_name: "Clickhouse::ActivityLog",
    foreign_key: :external_subscription_id,
    primary_key: :external_id

  has_one :lifetime_usage, autosave: true
  has_one :subscription_activity, class_name: "UsageMonitoring::SubscriptionActivity"

  validates :external_id, :billing_time, presence: true
  validate :validate_external_id, on: :create

  STATUSES = [
    :pending,
    :active,
    :terminated,
    :canceled
  ].freeze

  BILLING_TIME = %i[
    calendar
    anniversary
  ].freeze

  enum :status, STATUSES
  enum :billing_time, BILLING_TIME

  scope :starting_in_the_future, -> { pending.where(previous_subscription: nil) }

  # NOTE: SQL query to get subscription_at into customer timezone
  def self.subscription_at_in_timezone_sql
    <<-SQL
      subscriptions.subscription_at::timestamptz AT TIME ZONE
      COALESCE(customers.timezone, organizations.timezone, 'UTC')
    SQL
  end

  # NOTE: SQL query to get subscription_at into customer timezone
  def self.ending_at_in_timezone_sql
    <<-SQL
      subscriptions.ending_at::timestamptz AT TIME ZONE
      COALESCE(customers.timezone, organizations.timezone, 'UTC')
    SQL
  end

  def self.ransackable_attributes(_ = nil)
    %w[id name external_id]
  end

  def self.ransackable_associations(_ = nil)
    %w[customer plan]
  end

  def mark_as_active!(timestamp = Time.current)
    self.started_at ||= timestamp
    self.lifetime_usage ||= previous_subscription&.lifetime_usage || build_lifetime_usage(organization:)
    self.lifetime_usage.recalculate_invoiced_usage = true
    active!
  end

  def mark_as_terminated!(timestamp = Time.current)
    self.terminated_at ||= timestamp
    terminated!
  end

  def mark_as_canceled!
    self.canceled_at ||= Time.current
    canceled!
  end

  def upgraded?
    return false unless next_subscription

    plan.yearly_amount_cents <= next_subscription.plan.yearly_amount_cents
  end

  def downgraded?
    return false unless next_subscription

    plan.yearly_amount_cents > next_subscription.plan.yearly_amount_cents
  end

  def trial_end_date
    return unless plan.has_trial?

    initial_started_at.to_date + plan.trial_period.days
  end

  def trial_end_datetime
    return unless plan.has_trial?

    initial_started_at + plan.trial_period.days
  end

  def in_trial_period?
    return false if trial_ended_at
    return false if initial_started_at.future?

    trial_end_datetime.present? && trial_end_datetime.future?
  end

  def started_in_past?
    started_at.to_date < created_at.to_date
  end

  def initial_started_at
    customer.subscriptions
      .where(external_id:)
      .where.not(started_at: nil)
      .order(started_at: :asc).first&.started_at || subscription_at
  end

  def next_subscription
    next_subscriptions.reject(&:canceled?).max_by(&:created_at)
  end

  def already_billed?
    fees.subscription.any?
  end

  def starting_in_the_future?
    pending? && previous_subscription.nil?
  end

  def validate_external_id
    return unless active?
    return unless organization.subscriptions.active.exists?(external_id:)

    # NOTE: We want unique external id per organization.
    errors.add(:external_id, :value_already_exist)
  end

  def downgrade_plan_date
    return unless next_subscription
    return unless next_subscription.pending?

    ::Subscriptions::DatesService.new_instance(self, Time.current)
      .next_end_of_period.to_date + 1.day
  end

  def display_name
    name.presence || plan.name
  end

  def invoice_name
    name.presence || plan.invoice_name
  end

  # When upgrade, we want to bill one day less since date of the upgrade will be
  # included in the first invoice for the new plan
  def date_diff_with_timezone(from_datetime, to_datetime)
    number_od_days = Utils::Datetime.date_diff_with_timezone(
      from_datetime,
      to_datetime,
      customer.applicable_timezone
    )

    return number_od_days unless terminated? && upgraded?

    number_od_days -= 1

    number_od_days.negative? ? 0 : number_od_days
  end

  def should_sync_hubspot_subscription?
    customer.integration_customers.hubspot_kind.any? { |c| c.integration.sync_subscriptions }
  end

  def terminated_at?(timestamp)
    return false unless terminated?
    return false if terminated_at.nil? || timestamp.nil?

    # TODO: should be cleaned up to only use Time
    timestamp = timestamp.to_time if [Date, DateTime, String].include?(timestamp.class)
    timestamp = Time.zone.at(timestamp) if timestamp.is_a?(Integer)

    terminated_at.round <= timestamp.round
  end

  # TODO: Apply this method in CreateInvoiceSubscriptionService
  # This method calculates boundaries for terminated subscription. If termination is happening on billing date
  # new boundaries will be calculated only if there is no invoice subscription object for previous period.
  # Basically, we will bill regular subscription amount for previous period.
  # If subscription is happening on any other day, method is returning boundaries only for the used dates in
  # current period
  def adjusted_boundaries(datetime, boundaries)
    return boundaries unless terminated? && next_subscription.nil?

    # First we need to ensure that termination date is not started_at date. In that case boundaries are correct
    # and we should bill only one day. If this is not the case we should proceed.
    return boundaries if (datetime - 1.day) < started_at

    # Date service has various checks for terminated subscriptions. We want to avoid it and fetch boundaries
    # for current usage (current period) but when subscription was active (one day ago)
    duplicate = dup.tap { |s| s.status = :active }

    dates_service = Subscriptions::DatesService.new_instance(duplicate, datetime - 1.day, current_usage: true)
    return boundaries if datetime < dates_service.charges_to_datetime
    return boundaries unless (datetime - dates_service.charges_to_datetime) < 1.day

    # We should calculate boundaries as if subscription was not terminated
    dates_service = Subscriptions::DatesService.new_instance(duplicate, datetime, current_usage: false)

    previous_period_boundaries = {
      from_datetime: dates_service.from_datetime,
      to_datetime: dates_service.to_datetime,
      charges_from_datetime: dates_service.charges_from_datetime,
      charges_to_datetime: dates_service.charges_to_datetime,
      timestamp: datetime,
      charges_duration: dates_service.charges_duration_in_days
    }

    InvoiceSubscription.matching?(self, previous_period_boundaries) ? boundaries : previous_period_boundaries
  end
end

# == Schema Information
#
# Table name: subscriptions
#
#  id                       :uuid             not null, primary key
#  billing_time             :integer          default("calendar"), not null
#  canceled_at              :datetime
#  ending_at                :datetime
#  name                     :string
#  started_at               :datetime
#  status                   :integer          not null
#  subscription_at          :datetime
#  terminated_at            :datetime
#  trial_ended_at           :datetime
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  customer_id              :uuid             not null
#  external_id              :string           not null
#  organization_id          :uuid             not null
#  plan_id                  :uuid             not null
#  previous_subscription_id :uuid
#
# Indexes
#
#  index_subscriptions_on_customer_id                          (customer_id)
#  index_subscriptions_on_external_id                          (external_id)
#  index_subscriptions_on_organization_id                      (organization_id)
#  index_subscriptions_on_plan_id                              (plan_id)
#  index_subscriptions_on_previous_subscription_id_and_status  (previous_subscription_id,status)
#  index_subscriptions_on_started_at                           (started_at)
#  index_subscriptions_on_started_at_and_ending_at             (started_at,ending_at)
#  index_subscriptions_on_status                               (status)
#
# Foreign Keys
#
#  fk_rails_...  (customer_id => customers.id)
#  fk_rails_...  (organization_id => organizations.id)
#  fk_rails_...  (plan_id => plans.id)
#
