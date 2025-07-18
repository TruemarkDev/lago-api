# frozen_string_literal: true

module Charges
  module ChargeModels
    class GroupedService < BaseService
      Result = BaseResult[:grouped_results]

      def initialize(charge_model:, charge:, aggregation_result:, properties:)
        super(charge:, aggregation_result:, properties:)

        @charge_model = charge_model
      end

      def apply
        result.grouped_results = aggregation_result.aggregations.map do |aggregation|
          # Reassign the aggregator for per events logic
          aggregation.aggregator = aggregation_result.aggregator

          group_result = charge_model.apply(
            charge:,
            aggregation_result: aggregation,
            properties:
          )
          group_result.grouped_by = aggregation.grouped_by
          group_result
        end

        result
      end

      protected

      attr_accessor :charge_model
    end
  end
end
