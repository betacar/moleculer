require_relative "errors/local_node_already_registered"
require_relative "errors/action_not_found"
require_relative "errors/node_not_found"
require_relative "support"

module Moleculer
  ##
  # The Registry manages the available services on the network
  class Registry
    ##
    # @private
    class NodeList
      def initialize
        @nodes = Concurrent::Hash.new
      end

      def add_node(node)
        if @nodes[node.id]
          @nodes[node.id][:node] = node
        else
          @nodes[node.id] = { node: node, last_requested_at: Time.now }
        end
      end

      def remove_node(node_id)
        @nodes.delete(node_id)
      end

      def fetch_next_node
        node                                = @nodes.values.min_by { |a| a[:last_requested_at] }[:node]
        @nodes[node.id][:last_requested_at] = Time.now
        node
      end

      def fetch_node(node_id)
        @nodes.fetch(node_id)[:node]
      end

      def length
        @nodes.length
      end
    end

    ##
    # @private
    class ActionList
      def initialize
        @actions = Concurrent::Hash.new
      end

      def add(action)
        name             = "#{action.service.service_name}.#{action.name}"
        @actions[name] ||= NodeList.new
        @actions[name].add_node(action.node)
      end

      def remove_node(node_id)
        @actions.each do |k, a|
          a.remove_node(node_id)
          @actions.delete(k) if a.length.zero?
        end
      end

      def fetch_action(action_name)
        raise Errors::ActionNotFound, "The action '#{action_name}' was not found." unless @actions[action_name]

        @actions[action_name].fetch_next_node.actions[action_name]
      end
    end

    ##
    # @private
    class EventList
      ##
      # @private
      class Item
        def initialize
          @services = Concurrent::Hash.new
        end

        def add_service(service)
          @services[service.service_name] ||= NodeList.new
          @services[service.service_name].add_node(service.node)
        end

        def fetch_nodes
          @services.values.map(&:fetch_next_node)
        end

        def remove_node(node_id)
          @services.each do |k, list|
            list.remove_node(node_id)
            @services.delete(k) if list.length.zero?
          end
        end

        def length
          @services.map(&:length).inject(0) { |s, a| s + a }
        end
      end

      def initialize
        @events = Concurrent::Hash.new
      end

      def add(event)
        name            = event.name
        @events[name] ||= Item.new
        @events[name].add_service(event.service)
      end

      def remove_node(node_id)
        @events.each do |k, item|
          item.remove_node(node_id)
          @events.delete(k) if item.length.zero?
        end
      end

      def fetch_events(event_name)
        return [] unless @events[event_name]

        @events[event_name].fetch_nodes.map { |n| n.events[event_name] }.flatten
      end
    end

    private_constant :ActionList
    private_constant :EventList
    private_constant :NodeList

    include Support

    attr_reader :local_node

    ##
    # @param [Moleculer::Broker] broker the service broker instance
    def initialize(broker)
      @broker           = broker
      @nodes            = NodeList.new
      @actions          = ActionList.new
      @events           = EventList.new
      @services         = Concurrent::Hash.new
      @logger           = Moleculer.logger
      @remove_semaphore = Concurrent::Semaphore.new(1)
    end

    ##
    # Registers the node with the registry and updates the action/event handler lists.
    #
    # @param [Moleculer::Node] node the node to register
    #
    # @return [Moleculer::Node] the node that has been registered
    def register_node(node)
      return local_node if @local_node && node.id == @local_node.id

      if node.local?
        raise Errors::LocalNodeAlreadyRegistered, "A LOCAL node has already been registered" if @local_node

        @logger.info "registering LOCAL node '#{node.id}'"
        @local_node = node
      end
      @logger.info "registering node #{node.id}" unless node.local?
      @nodes.add_node(node)
      update_services(node)
      update_actions(node)
      update_events(node)
      node
    end

    ##
    # Gets the named action from the registry. If a local action exists it will return the local one instead of a
    # remote action.
    #
    # @param action_name [String] the name of the action
    #
    # @return [Moleculer::Service::Action|Moleculer::RemoteService::Action]
    def fetch_action(action_name)
      @actions.fetch_action(action_name)
    end

    ##
    # Fetches all the events for the given event name that should be used to emit an event. This is load balanced, and
    # will fetch a different node for nodes that duplicate the service/event
    #
    # @param event_name [String] the name of the even to fetch
    #
    # @return [Array<Moleculer::Service::Event>] the events that that should be emitted to
    def fetch_events_for_emit(event_name)
      @events.fetch_events(event_name)
    end

    ##
    # It fetches the given node, and raises an exception if the node does not exist
    #
    # @param node_id [String] the id of the node to fetch
    #
    # @return [Moleculer::Node] the moleculer node with the given id
    # @raise [Moleculer::Errors::NodeNotFound] if the node was not found
    def fetch_node(node_id)
      @nodes.fetch_node(node_id)
    rescue KeyError
      raise Errors::NodeNotFound, "The node with the id '#{node_id}' was not found."
    end

    ##
    # Fetches the given node, and returns nil if the node was not found
    #
    # @param node_id [String] the id of the node to fetch
    #
    # @return [Moleculer::Node] the moleculer node with the given id
    def safe_fetch_node(node_id)
      fetch_node(node_id)
    rescue Errors::NodeNotFound
      nil
    end

    ##
    # Gets the named action from the registry for the given node. Raises an error if the node does not exist or the node
    # does not have the specified action.
    #
    # @param action_name [String] the name of the action
    # @param node_id [String] the id of the node from which to get the action
    #
    # @return [Moleculer::Service::Action] the action from the specified node_id
    # @raise [Moleculer::NodeNotFound] raised when the specified node_id was not found
    # @raise [Moleculer::ActionNotFound] raised when the specified action was not found on the specified node
    def fetch_action_for_node_id(action_name, node_id)
      node = fetch_node(node_id)
      fetch_action_from_node(action_name, node)
    end

    def missing_services(*services)
      services - @services.keys
    end

    ##
    # Removes the node with the given id. Because this must act across multiple indexes this action uses a semaphore to
    # reduce the chance of race conditions.
    #
    # @param node_id [String] the node to remove
    def remove_node(node_id)
      @remove_semaphore.acquire
      @logger.info "removing node '#{node_id}'"
      @nodes.remove_node(node_id)
      @actions.remove_node(node_id)
      @events.remove_node(node_id)
      @remove_semaphore.release
    end

    private

    def get_local_action(name)
      @local_node.actions.select { |a| a.name == name.to_s }.first
    end

    def update_node_for_load_balancer(node)
      @nodes[node.id][:last_called_at] = Time.now
    end

    def fetch_event_from_node(event_name, node)
      node.events.fetch(event_name)
    rescue KeyError
      raise Errors::EventNotFound, "The event '#{event_name}' was not found on the node id with id '#{node.id}'"
    end

    def fetch_next_nodes_for_event(event_name)
      service_names = HashUtil.fetch(@events, event_name, {}).keys
      node_names    = service_names.map { |s| @services[s] }
      nodes         = node_names.map { |names| names.map { |name| @nodes[name] } }
      nodes.map { |node_list| node_list.min_by { |a| a[:last_called_at] }[:node] }
    end

    def remove_node_from_events(node_id)
      @events.values.each do |event|
        event.values.each do |list|
          list.reject! { |id| id == node_id }
        end
      end
    end

    def update_actions(node)
      node.actions.values.each do |action|
        @actions.add(action)
      end
      @logger.debug "registered #{node.actions.length} action(s) for node '#{node.id}'"
    end

    def update_events(node)
      node.events.values.each do |events|
        events.each { |e| @events.add(e) }
      end
      @logger.debug "registered #{node.events.length} event(s) for node '#{node.id}'"
    end

    def update_services(node)
      node.services.values.each do |service|
        @services[service.service_name] ||= NodeList.new
        @services[service.service_name].add_node(node)
      end
    end
  end
end
