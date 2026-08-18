# frozen_string_literal: true

require 'spec_helper'

module Legion
  module Extensions
    module Actors
      unless const_defined?(:Subscription, false)
        class Subscription
          def initialize(*) = true
        end
      end
    end
  end
end

require 'legion/extensions/llm/bedrock/actors/fleet_worker'

RSpec.describe Legion::Extensions::Llm::Bedrock::Actor::FleetWorker do
  subject(:actor) { described_class.new }

  it 'uses the shared logging helper' do
    expect(described_class.ancestors).to include(Legion::Logging::Helper)
  end

  it 'uses the provider-owned fleet runner' do
    # The Subscription dispatch path sends the decoded message to the runner
    # class directly (runner_class.send(runner_function, **message)), so
    # runner_class must be the runner constant, not a String.
    expect(actor.runner_class).to eq(Legion::Extensions::Llm::Bedrock::Runners::FleetWorker)
    expect(actor.runner_function).to eq('handle_fleet_request')
    expect(actor.use_runner?).to be(false)
  end

  it 'dispatches a decoded message exactly the way the Subscription path does' do
    message = {
      request_id: 'req-1', provider: 'bedrock', provider_instance: 'us-east-1/ak:01234567',
      operation: 'chat', model: 'us.anthropic.claude-sonnet-4-6', params: { messages: [] },
      routing_key: 'llm.fleet.runners.fleet_worker.#', message_id: 'm-1'
    }
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:ok)

    # The exact invocation form from Legion::Extensions::Actors::Subscription:
    #   runner_class.send(fn, **message)
    result = actor.runner_class.send(actor.runner_function, **message)

    expect(result).to eq(:ok)
    expect(Legion::Extensions::Llm::Fleet::ProviderResponder).to have_received(:call).with(
      hash_including(payload: message, provider_family: :bedrock)
    )
  end

  it 'is enabled only when at least one provider instance responds to fleet requests' do
    allow(Legion::Extensions::Llm::Bedrock).to receive(:discover_instances)
      .and_return(local: { fleet: { respond_to_requests: true } })

    expect(actor.enabled?).to be(true)
  end
end
