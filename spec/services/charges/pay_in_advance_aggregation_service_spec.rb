# frozen_string_literal: true

require "rails_helper"

RSpec.describe Charges::PayInAdvanceAggregationService, type: :service do
  subject(:agg_service) do
    described_class.new(charge:, boundaries:, properties:, event:, charge_filter:)
  end

  let(:organization) { create(:organization) }
  let(:billable_metric) { create(:billable_metric, organization:, aggregation_type:, field_name: "item_id") }
  let(:charge) { create(:standard_charge, billable_metric:, pay_in_advance: true) }
  let(:charge_filter) { nil }
  let(:aggregation_type) { "count_agg" }
  let(:event) { create(:event, organization:, external_subscription_id: subscription.external_id) }
  let(:properties) { {} }

  let(:customer) { create(:customer, organization:) }

  let(:subscription) do
    create(:subscription, customer:, started_at: DateTime.parse("2023-03-15"))
  end

  let(:boundaries) do
    {
      charges_from_datetime: subscription.started_at.beginning_of_day,
      charges_to_datetime: subscription.started_at.end_of_month.end_of_day
    }
  end

  let(:agg_result) { BaseService::Result.new }

  describe "#call" do
    describe "when count aggregation" do
      let(:count_service) { instance_double(BillableMetrics::Aggregations::CountService, aggregate: agg_result) }

      it "delegates to the count aggregation service" do
        allow(BillableMetrics::Aggregations::CountService).to receive(:new).and_return(count_service)

        agg_service.call

        expect(BillableMetrics::Aggregations::CountService).to have_received(:new)
          .with(
            event_store_class: Events::Stores::PostgresStore,
            charge:,
            subscription:,
            boundaries: {
              from_datetime: boundaries[:charges_from_datetime],
              to_datetime: boundaries[:charges_to_datetime],
              charges_duration: boundaries[:charges_duration]
            },
            filters: {
              event:
            }
          )

        expect(count_service).to have_received(:aggregate).with(
          options: {free_units_per_events: 0, free_units_per_total_aggregation: 0}
        )
      end

      # TODO(pricing_group_keys): remove after deprecation of grouped_by
      describe "when charge model has grouped_by property" do
        let(:charge) do
          create(
            :standard_charge,
            billable_metric:,
            pay_in_advance: true,
            properties: {"grouped_by" => ["operator"], "amount" => "100"}
          )
        end

        let(:event) do
          create(
            :event,
            organization:,
            external_subscription_id: subscription.external_id,
            properties: {"operator" => "foo"}
          )
        end

        it "delegates to the count aggregation service" do
          allow(BillableMetrics::Aggregations::CountService).to receive(:new).and_return(count_service)

          agg_service.call

          expect(BillableMetrics::Aggregations::CountService).to have_received(:new)
            .with(
              event_store_class: Events::Stores::PostgresStore,
              charge:,
              subscription:,
              boundaries: {
                from_datetime: boundaries[:charges_from_datetime],
                to_datetime: boundaries[:charges_to_datetime],
                charges_duration: boundaries[:charges_duration]
              },
              filters: {
                event:,
                grouped_by_values: {"operator" => "foo"}
              }
            )

          expect(count_service).to have_received(:aggregate).with(
            options: {free_units_per_events: 0, free_units_per_total_aggregation: 0}
          )
        end
      end

      describe "when charge model has pricing_group_keys property" do
        let(:charge) do
          create(
            :standard_charge,
            billable_metric:,
            pay_in_advance: true,
            properties: {"pricing_group_keys" => ["operator"], "amount" => "100"}
          )
        end

        let(:event) do
          create(
            :event,
            organization:,
            external_subscription_id: subscription.external_id,
            properties: {"operator" => "foo"}
          )
        end

        it "delegates to the count aggregation service" do
          allow(BillableMetrics::Aggregations::CountService).to receive(:new).and_return(count_service)

          agg_service.call

          expect(BillableMetrics::Aggregations::CountService).to have_received(:new)
            .with(
              event_store_class: Events::Stores::PostgresStore,
              charge:,
              subscription:,
              boundaries: {
                from_datetime: boundaries[:charges_from_datetime],
                to_datetime: boundaries[:charges_to_datetime],
                charges_duration: boundaries[:charges_duration]
              },
              filters: {
                event:,
                grouped_by_values: {"operator" => "foo"}
              }
            )

          expect(count_service).to have_received(:aggregate).with(
            options: {free_units_per_events: 0, free_units_per_total_aggregation: 0}
          )
        end
      end

      describe "when charge filter is present" do
        let(:charge_filter) { create(:charge_filter, charge:) }
        let(:filter) { create(:billable_metric_filter, billable_metric: charge.billable_metric) }

        let(:filter_value) do
          create(
            :charge_filter_value,
            charge_filter:,
            billable_metric_filter: filter,
            values: [filter.values.first]
          )
        end

        before { filter_value }

        it "delegates to the count aggregation service" do
          allow(BillableMetrics::Aggregations::CountService).to receive(:new).and_return(count_service)

          agg_service.call

          expect(BillableMetrics::Aggregations::CountService).to have_received(:new)
            .with(
              event_store_class: Events::Stores::PostgresStore,
              charge:,
              subscription:,
              boundaries: {
                from_datetime: boundaries[:charges_from_datetime],
                to_datetime: boundaries[:charges_to_datetime],
                charges_duration: boundaries[:charges_duration]
              },
              filters: {
                event:,
                charge_filter:,
                matching_filters: charge_filter.to_h,
                ignored_filters: []
              }
            )

          expect(count_service).to have_received(:aggregate).with(
            options: {free_units_per_events: 0, free_units_per_total_aggregation: 0}
          )
        end
      end
    end

    describe "when sum aggregation" do
      let(:aggregation_type) { "sum_agg" }
      let(:sum_service) { instance_double(BillableMetrics::Aggregations::SumService, aggregate: agg_result) }
      let(:properties) do
        {"free_units_per_events" => "3", "free_units_per_total_aggregation" => "50"}
      end

      it "delegates to the sum aggregation service" do
        allow(BillableMetrics::Aggregations::SumService).to receive(:new).and_return(sum_service)

        agg_service.call

        expect(BillableMetrics::Aggregations::SumService).to have_received(:new)
          .with(
            event_store_class: Events::Stores::PostgresStore,
            charge:,
            subscription:,
            boundaries: {
              from_datetime: boundaries[:charges_from_datetime],
              to_datetime: boundaries[:charges_to_datetime],
              charges_duration: boundaries[:charges_duration]
            },
            filters: {
              event:
            }
          )

        expect(sum_service).to have_received(:aggregate).with(
          options: {free_units_per_events: 3, free_units_per_total_aggregation: 50}
        )
      end
    end

    describe "when unique_count aggregation" do
      let(:aggregation_type) { "unique_count_agg" }
      let(:unique_count_service) do
        instance_double(BillableMetrics::Aggregations::UniqueCountService, aggregate: agg_result)
      end

      it "delegates to the sum aggregation service" do
        allow(BillableMetrics::Aggregations::UniqueCountService).to receive(:new).and_return(unique_count_service)

        agg_service.call

        expect(BillableMetrics::Aggregations::UniqueCountService).to have_received(:new)
          .with(
            event_store_class: Events::Stores::PostgresStore,
            charge:,
            subscription:,
            boundaries: {
              from_datetime: boundaries[:charges_from_datetime],
              to_datetime: boundaries[:charges_to_datetime],
              charges_duration: boundaries[:charges_duration]
            },
            filters: {
              event:
            }
          )

        expect(unique_count_service).to have_received(:aggregate).with(
          options: {free_units_per_events: 0, free_units_per_total_aggregation: 0}
        )
      end
    end
  end
end
