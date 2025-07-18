# frozen_string_literal: true

require "rails_helper"

RSpec.describe Integrations::Hubspot::Invoices::DeployObjectService do
  subject(:deploy_object_service) { described_class.new(integration:) }

  let(:integration) { create(:hubspot_integration) }

  describe ".call" do
    let(:http_client) { instance_double(LagoHttpClient::Client) }
    let(:http_client_get) { instance_double(LagoHttpClient::Client) }
    let(:endpoint) { "https://api.nango.dev/v1/hubspot/object" }
    let(:customer_object_endpoint) { "https://api.nango.dev/v1/hubspot/custom-object" }
    let(:response) { instance_double("Response", success?: true) }

    let(:get_response) do
      path = Rails.root.join("spec/fixtures/integration_aggregator/custom_object_response.json")
      JSON.parse(File.read(path))
    end

    before do
      allow(LagoHttpClient::Client).to receive(:new)
        .with(endpoint, retries_on: [OpenSSL::SSL::SSLError])
        .and_return(http_client)
      allow(LagoHttpClient::Client).to receive(:new)
        .with(customer_object_endpoint, retries_on: [OpenSSL::SSL::SSLError])
        .and_return(http_client_get)
      allow(http_client).to receive(:post_with_response).and_return(response)
      allow(http_client_get).to receive(:get).and_raise LagoHttpClient::HttpError.new("error", "error", nil)
      allow(response).to receive(:[]).with("objectTypeId").and_return("123")

      integration.invoices_properties_version = nil
      integration.save!
    end

    it "successfully deploys invoice custom object and updates the invoices_properties_version" do
      deploy_object_service.call

      aggregate_failures do
        expect(LagoHttpClient::Client).to have_received(:new).with(endpoint, retries_on: [OpenSSL::SSL::SSLError])
        expect(http_client).to have_received(:post_with_response) do |payload, headers|
          expect(payload[:name]).to eq("LagoInvoices")
          expect(headers["Authorization"]).to include("Bearer")
        end
        expect(integration.reload.invoices_properties_version).to eq(described_class::VERSION)
      end
    end

    context "when invoices_properties_version is already up-to-date" do
      before do
        integration.invoices_properties_version = described_class::VERSION
        integration.save!
      end

      it "does not make an API call and keeps the version unchanged" do
        deploy_object_service.call

        aggregate_failures do
          expect(LagoHttpClient::Client).not_to have_received(:new)
          expect(http_client).not_to have_received(:post_with_response)
          expect(integration.reload.invoices_properties_version).to eq(described_class::VERSION)
        end
      end
    end

    context "when custom object service returns a valid objectTypeId" do
      let(:custom_object_result) do
        instance_double(
          "CustomObjectResult",
          success?: true,
          custom_object: instance_double("CustomObject", objectTypeId: "123")
        )
      end

      before do
        allow(http_client).to receive(:get).and_return(get_response)
        allow(Integrations::Aggregator::CustomObjectService).to receive(:call).and_return(custom_object_result)
      end

      it "saves the objectTypeId and updates the invoices_properties_version" do
        deploy_object_service.call

        aggregate_failures do
          expect(integration.reload.invoices_object_type_id).to eq("123")
          expect(integration.reload.invoices_properties_version).to eq(described_class::VERSION)
        end
      end
    end

    context "when custom object service does not return a valid objectTypeId" do
      let(:custom_object_result) do
        instance_double("CustomObjectResult", success?: false)
      end

      before do
        allow(Integrations::Aggregator::CustomObjectService).to receive(:call).and_return(custom_object_result)
      end

      it "makes an API call and updates the invoices_properties_version" do
        deploy_object_service.call

        aggregate_failures do
          expect(LagoHttpClient::Client).to have_received(:new).with(endpoint, retries_on: [OpenSSL::SSL::SSLError])
          expect(http_client).to have_received(:post_with_response)
          expect(integration.reload.invoices_properties_version).to eq(described_class::VERSION)
        end
      end
    end

    context "when an HTTP error occurs" do
      let(:error) { LagoHttpClient::HttpError.new("error message", '{"error": {"message": "unknown failure"}}', nil) }

      before do
        allow(http_client).to receive(:post_with_response).and_raise(error)
      end

      it "delivers an integration error webhook" do
        expect { deploy_object_service.call }.to enqueue_job(SendWebhookJob)
          .with(
            "integration.provider_error",
            integration,
            provider: "hubspot",
            provider_code: integration.code,
            provider_error: {
              message: "unknown failure",
              error_code: "integration_error"
            }
          )
      end
    end
  end
end
