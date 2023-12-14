# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::Customers::ViesCheckService do
  subject(:webhook_service) { described_class.new(object: customer) }

  let(:organization) { create(:organization) }
  let(:customer) { create(:customer, organization:) }

  describe '.call' do
    let(:lago_client) { instance_double(LagoHttpClient::Client) }

    before do
      allow(LagoHttpClient::Client).to receive(:new)
        .with(organization.webhook_endpoints.first.webhook_url)
        .and_return(lago_client)
      allow(lago_client).to receive(:post_with_response)
    end

    it 'builds payload with customer.vies_check webhook type' do
      webhook_service.call

      expect(LagoHttpClient::Client).to have_received(:new)
        .with(organization.webhook_endpoints.first.webhook_url)
      expect(lago_client).to have_received(:post_with_response) do |payload|
        expect(payload[:webhook_type]).to eq('customer.vies_check')
        expect(payload[:object_type]).to eq('customer')
      end
    end
  end
end
