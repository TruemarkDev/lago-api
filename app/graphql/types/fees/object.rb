# frozen_string_literal: true

module Types
  module Fees
    class Object < Types::BaseObject
      graphql_name "Fee"
      implements Types::Invoices::InvoiceItem

      field :charge, Types::Charges::Object, null: true
      field :currency, Types::CurrencyEnum, null: false
      field :description, String, null: true
      field :grouped_by, GraphQL::Types::JSON, null: false
      field :invoice_display_name, String, null: true
      field :invoice_name, String, null: true
      field :subscription, Types::Subscriptions::Object, null: true
      field :true_up_fee, Types::Fees::Object, null: true
      field :true_up_parent_fee, Types::Fees::Object, null: true

      field :creditable_amount_cents, GraphQL::Types::BigInt, null: false
      field :events_count, GraphQL::Types::BigInt, null: true
      field :fee_type, Types::Fees::TypesEnum, null: false
      field :precise_unit_amount, GraphQL::Types::Float, null: false
      field :succeeded_at, GraphQL::Types::ISO8601DateTime, null: true
      field :taxes_amount_cents, GraphQL::Types::BigInt, null: false
      field :taxes_rate, GraphQL::Types::Float, null: true
      field :units, GraphQL::Types::Float, null: false

      field :applied_taxes, [Types::Fees::AppliedTaxes::Object]

      field :amount_details, Types::Fees::AmountDetails::Object, null: true

      field :adjusted_fee, Boolean, null: false
      field :adjusted_fee_type, Types::AdjustedFees::AdjustedFeeTypeEnum, null: true

      field :charge_filter, Types::ChargeFilters::Object, null: true
      field :pricing_unit_usage, Types::PricingUnitUsages::Object, null: true

      def item_type
        object.fee_type
      end

      def applied_taxes
        object.applied_taxes.order(tax_rate: :desc)
      end

      def adjusted_fee
        object.adjusted_fee.present?
      end

      def adjusted_fee_type
        return nil if object.adjusted_fee.blank?
        return nil if object.adjusted_fee.adjusted_display_name?

        object.adjusted_fee.adjusted_units? ? "adjusted_units" : "adjusted_amount"
      end
    end
  end
end
