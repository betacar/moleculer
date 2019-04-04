RSpec.describe Moleculer::Node do
  let(:service_1) do
    Class.new(Moleculer::Service::Base) do
      service_name "service-1"
      action "test", :action_1
      action "another_test", :action_2
      event "something.happened", :event_1
      event "something-else.happened", :event_2

      def action_1; end

      def action_2; end

      def event_1; end

      def event_2; end
    end
  end

  let(:action_1_1) { service_1.actions.values.first }
  let(:action_1_2) { service_1.actions.values.last }
  let(:event_1_1)  { service_1.events.values.first }
  let(:event_1_2)  { service_1.events.values.last  }

  let(:service_2) do
    Class.new(Moleculer::Service::Base) do
      service_name "service-2"
      action "test", :action_1
      event "something.happened", :event_1

      def action_1; end

      def event_1; end
    end
  end

  let(:action_2_1) { service_2.actions.values.last }
  let(:event_2_1)  { service_2.events.values.last }

  subject do
    Moleculer::Node.new(
      node_id:  "test-node",
      services: [service_1, service_2],
    )
  end

  describe "#actions" do
    it "should return the services actions" do
      expect(subject.actions).to eq(
        "service-1.test"         => action_1_1,
        "service-1.another_test" => action_1_2,
        "service-2.test"         => action_2_1,
      )
    end
  end

  describe "#events" do
    it "should return all events for all services" do
      expect(subject.events).to eq(
        "something.happened"      => [event_1_1, event_2_1],
        "something-else.happened" => [event_1_2],
      )
    end
  end
end
