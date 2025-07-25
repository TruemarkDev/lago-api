# frozen_string_literal: true

module Types
  # QueryType
  class QueryType < Types::BaseObject
    # Add `node(id: ID!) and `nodes(ids: [ID!]!)`
    include GraphQL::Types::Relay::HasNodeField
    include GraphQL::Types::Relay::HasNodesField

    field :current_user, resolver: Resolvers::CurrentUserResolver

    field :activity_log, resolver: Resolvers::ActivityLogResolver
    field :activity_logs, resolver: Resolvers::ActivityLogsResolver
    field :add_on, resolver: Resolvers::AddOnResolver
    field :add_ons, resolver: Resolvers::AddOnsResolver
    field :alert, resolver: Resolvers::UsageMonitoring::AlertResolver
    field :alerts, resolver: Resolvers::UsageMonitoring::SubscriptionAlertsResolver
    field :api_key, resolver: Resolvers::ApiKeyResolver
    field :api_keys, resolver: Resolvers::ApiKeysResolver
    field :api_log, resolver: Resolvers::ApiLogResolver
    field :api_logs, resolver: Resolvers::ApiLogsResolver
    field :billable_metric, resolver: Resolvers::BillableMetricResolver
    field :billable_metrics, resolver: Resolvers::BillableMetricsResolver
    field :billing_entities, resolver: Resolvers::BillingEntitiesResolver
    field :billing_entity, resolver: Resolvers::BillingEntityResolver
    field :billing_entity_taxes, resolver: Resolvers::BillingEntityTaxesResolver
    field :coupon, resolver: Resolvers::CouponResolver
    field :coupons, resolver: Resolvers::CouponsResolver
    field :credit_note, resolver: Resolvers::CreditNoteResolver
    field :credit_note_estimate, resolver: Resolvers::CreditNotes::EstimateResolver
    field :credit_notes, resolver: Resolvers::CreditNotesResolver
    field :current_version, resolver: Resolvers::VersionResolver
    field :customer, resolver: Resolvers::CustomerResolver
    field :customer_invoices, resolver: Resolvers::Customers::InvoicesResolver
    field :customer_portal_customer_usage, resolver: Resolvers::CustomerPortal::Customers::UsageResolver
    field :customer_portal_invoice_collections, resolver: Resolvers::CustomerPortal::Analytics::InvoiceCollectionsResolver
    field :customer_portal_invoices, resolver: Resolvers::CustomerPortal::InvoicesResolver
    field :customer_portal_organization, resolver: Resolvers::CustomerPortal::OrganizationResolver
    field :customer_portal_overdue_balances, resolver: Resolvers::CustomerPortal::Analytics::OverdueBalancesResolver
    field :customer_portal_subscription, resolver: Resolvers::CustomerPortal::SubscriptionResolver
    field :customer_portal_subscriptions, resolver: Resolvers::CustomerPortal::SubscriptionsResolver
    field :customer_portal_user, resolver: Resolvers::CustomerPortal::CustomerResolver
    field :customer_portal_wallets, resolver: Resolvers::CustomerPortal::WalletsResolver
    field :customer_usage, resolver: Resolvers::Customers::UsageResolver
    field :customers, resolver: Resolvers::CustomersResolver
    field :dunning_campaign, resolver: Resolvers::DunningCampaignResolver
    field :dunning_campaigns, resolver: Resolvers::DunningCampaignsResolver
    field :event, resolver: Resolvers::EventResolver
    field :events, resolver: Resolvers::EventsResolver
    field :feature, resolver: Resolvers::Entitlement::FeatureResolver
    field :features, resolver: Resolvers::Entitlement::FeaturesResolver
    field :google_auth_url, resolver: Resolvers::Auth::Google::AuthUrlResolver
    field :gross_revenues, resolver: Resolvers::Analytics::GrossRevenuesResolver
    field :integration, resolver: Resolvers::IntegrationResolver
    field :integration_collection_mapping, resolver: Resolvers::IntegrationCollectionMappingResolver
    field :integration_collection_mappings, resolver: Resolvers::IntegrationCollectionMappingsResolver
    field :integration_items, resolver: Resolvers::IntegrationItemsResolver
    field :integration_mapping, resolver: Resolvers::IntegrationMappingResolver
    field :integration_mappings, resolver: Resolvers::IntegrationMappingsResolver
    field :integration_subsidiaries, resolver: Resolvers::Integrations::SubsidiariesResolver
    field :integrations, resolver: Resolvers::IntegrationsResolver
    field :invite, resolver: Resolvers::InviteResolver
    field :invites, resolver: Resolvers::InvitesResolver
    field :invoice, resolver: Resolvers::InvoiceResolver
    field :invoice_collections, resolver: Resolvers::Analytics::InvoiceCollectionsResolver
    field :invoice_credit_notes, resolver: Resolvers::InvoiceCreditNotesResolver
    field :invoice_custom_section, resolver: Resolvers::InvoiceCustomSectionResolver
    field :invoice_custom_sections, resolver: Resolvers::InvoiceCustomSectionsResolver
    field :invoiced_usages, resolver: Resolvers::Analytics::InvoicedUsagesResolver
    field :invoices, resolver: Resolvers::InvoicesResolver
    field :memberships, resolver: Resolvers::MembershipsResolver
    field :mrrs, resolver: Resolvers::Analytics::MrrsResolver
    field :organization, resolver: Resolvers::OrganizationResolver
    field :overdue_balances, resolver: Resolvers::Analytics::OverdueBalancesResolver
    field :password_reset, resolver: Resolvers::PasswordResetResolver
    field :payment, resolver: Resolvers::PaymentResolver
    field :payment_provider, resolver: Resolvers::PaymentProviderResolver
    field :payment_providers, resolver: Resolvers::PaymentProvidersResolver
    field :payment_requests, resolver: Resolvers::PaymentRequestsResolver
    field :payments, resolver: Resolvers::PaymentsResolver
    field :plan, resolver: Resolvers::PlanResolver
    field :plans, resolver: Resolvers::PlansResolver
    field :pricing_unit, resolver: Resolvers::PricingUnitResolver
    field :pricing_units, resolver: Resolvers::PricingUnitsResolver
    field :subscription, resolver: Resolvers::SubscriptionResolver
    field :subscriptions, resolver: Resolvers::SubscriptionsResolver
    field :tax, resolver: Resolvers::TaxResolver
    field :taxes, resolver: Resolvers::TaxesResolver
    field :wallet, resolver: Resolvers::WalletResolver
    field :wallet_transaction, resolver: Resolvers::WalletTransactionResolver
    field :wallet_transactions, resolver: Resolvers::WalletTransactionsResolver
    field :wallets, resolver: Resolvers::WalletsResolver
    field :webhook, resolver: Resolvers::WebhookResolver
    field :webhook_endpoint, resolver: Resolvers::WebhookEndpointResolver
    field :webhook_endpoints, resolver: Resolvers::WebhookEndpointsResolver
    field :webhooks, resolver: Resolvers::WebhooksResolver

    field :data_api_mrrs, resolver: Resolvers::DataApi::MrrsResolver
    field :data_api_mrrs_plans, resolver: Resolvers::DataApi::Mrrs::PlansResolver
    field :data_api_prepaid_credits, resolver: Resolvers::DataApi::PrepaidCreditsResolver
    field :data_api_revenue_streams, resolver: Resolvers::DataApi::RevenueStreamsResolver
    field :data_api_revenue_streams_customers, resolver: Resolvers::DataApi::RevenueStreams::CustomersResolver
    field :data_api_revenue_streams_plans, resolver: Resolvers::DataApi::RevenueStreams::PlansResolver
    field :data_api_usages, resolver: Resolvers::DataApi::UsagesResolver
    field :data_api_usages_aggregated_amounts, resolver: Resolvers::DataApi::Usages::AggregatedAmountsResolver
    field :data_api_usages_invoiced, resolver: Resolvers::DataApi::Usages::InvoicedResolver
  end
end
