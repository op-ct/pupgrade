require 'pupgrade/surface/diff'
require 'pupgrade/surface/render'

module Pupgrade
  module Impact
    # Turns the surface changes of one module into findings about the site:
    # each change the evidence shows the site touching, and where. Without
    # evidence every change is a finding with its use unknown.
    class Analysis
      KINDS = %w[
        class-removed class-param-removed class-param-hiera-only class-param-added-required class-param-type-changed class-param-default-changed
        define-removed define-param-removed define-param-added-required define-param-type-changed define-param-default-changed
        function-removed function-changed
        type-removed type-attribute-removed type-attribute-changed
        provider-removed fact-removed type-alias-removed type-alias-changed
      ].freeze

      # One thing the site would feel.
      #
      # @!attribute [r] module
      #   @return [String] the module moving
      # @!attribute [r] kind
      #   @return [String] one of {KINDS}
      # @!attribute [r] subject
      #   @return [String] the class, function, type, or fact, with its
      #     parameter when one is concerned
      # @!attribute [r] uses
      #   @return [Array<Use>, nil] the nodes, resources, call sites, or
      #     Hiera files concerned; empty when nothing uses it; nil without
      #     evidence, the use unknown
      # @!attribute [r] detail
      #   @return [String] the surface change
      Finding = Data.define(:module, :kind, :subject, :uses, :detail) do
        # Whether the evidence shows the site touching it; a use unknown is
        # neither a use nor its absence.
        def used?
          !uses.nil? && !uses.empty?
        end

        # @return [String] "nodes: a, b; hiera: data/common.yaml:5", "use
        #   unknown", or "" when nothing uses it
        def where
          uses.nil? ? 'use unknown' : uses.join('; ')
        end
      end

      # One kind of use of a finding: its first {NAMED} items, and a count
      # of the rest.
      #
      # @!attribute [r] label
      #   @return [String] "nodes", "resources", "sites", "hiera", or "lookups"
      # @!attribute [r] items
      #   @return [Array<Item>] the first {NAMED}
      # @!attribute [r] more
      #   @return [Integer] how many more there are
      Use = Data.define(:label, :items, :more) do
        def to_s
          "#{label}: #{items.join(', ')}#{" and #{more} more" if more.positive?}"
        end
      end

      # One node, resource, call site, or Hiera file.
      #
      # @!attribute [r] name
      #   @return [String, nil] a resource's "Type[title]", or a file:line;
      #     nil for a node
      # @!attribute [r] certname
      #   @return [String, nil] the node; nil for a file:line
      Item = Data.define(:name, :certname) do
        def to_s
          [name, certname].compact.join(' on ')
        end
      end

      # How many names a `where` lists before counting instead.
      NAMED = 3

      # @param evidence [Evidence, nil]
      # @param hiera [Hash{String => Array<String>}] every top-level Hiera
      #   key to the data files setting it, each "path:line"
      # @param lookups [Hash{String => Array<String>}] every key some
      #   lookup() reads to its call sites, each "path:line"
      def initialize(evidence: nil, hiera: {}, lookups: {})
        @evidence = evidence
        @hiera    = hiera
        @lookups  = lookups
      end

      # @param name [String] the module
      # @param changes [Array<Surface::Diff::Change>] between its two surfaces
      # @param to [Hash] the proposed surface, for what an entry became
      # @return [Array<Finding>]
      def findings(name, changes, to)
        changes.flat_map { |c| finding(name, c, to) }.compact
      end

      private

      def finding(name, change, to)
        case change.section
        when 'classes'       then class_findings(name, change, to)
        when 'defined_types' then define_findings(name, change, to)
        when 'functions'     then function_findings(name, change)
        when 'types'         then type_findings(name, change, to)
        when 'providers'     then provider_findings(name, change)
        when 'facts'         then fact_findings(name, change)
        when 'type_aliases'  then alias_findings(name, change)
        else []
        end
      end

      def class_findings(name, change, to)
        klass = change.name
        case change.kind
        when 'removed'
          [make(name, 'class-removed', klass, nodes(@evidence&.including(klass)) + hiera_under(klass), change)]
        when 'changed'
          param, what = param_change(change)
          return [] unless param

          case what
          when :removed
            # a key some lookup() still reads lives on as plain Hiera data; one nothing reads is dead
            key   = "#{klass}::#{param}"
            sites = Array(@lookups[key])
            kind  = sites.empty? ? 'class-param-removed' : 'class-param-hiera-only'
            where = nodes(@evidence&.setting(klass, param)) + hiera(key) + (sites.empty? ? [] : [list('lookups', sites)])
            [make(name, kind, key, where, change)]
          when :added
            return [] unless required?(to.dig('classes', klass, 'params', param))

            [make(name, 'class-param-added-required', "#{klass}::#{param}", nodes(@evidence&.including(klass)), change)]
          when :type
            [make(name, 'class-param-type-changed', "#{klass}::#{param}", nodes(@evidence&.setting(klass, param)) + hiera("#{klass}::#{param}"), change)]
          when :default
            [make(name, 'class-param-default-changed', "#{klass}::#{param}", nodes(@evidence&.defaulting(klass, param)), change)]
          else []
          end
        else []
        end
      end

      def define_findings(name, change, to)
        type = change.name
        case change.kind
        when 'removed'
          [make(name, 'define-removed', type, resources(@evidence&.resources(type)), change)]
        when 'changed'
          param, what = param_change(change)
          return [] unless param

          case what
          when :removed
            [make(name, 'define-param-removed', "#{type} #{param}", resources(@evidence&.resources(type, with: param)), change)]
          when :added
            return [] unless required?(to.dig('defined_types', type, 'params', param))

            lacking = @evidence&.resources(type)&.reject { |_, r| r['parameters'].key?(param) }
            [make(name, 'define-param-added-required', "#{type} #{param}", resources(lacking), change)]
          when :type
            [make(name, 'define-param-type-changed', "#{type} #{param}", resources(@evidence&.resources(type, with: param)), change)]
          when :default
            defaulting = @evidence&.resources(type)&.reject { |_, r| r['parameters'].key?(param) }
            [make(name, 'define-param-default-changed', "#{type} #{param}", resources(defaulting), change)]
          else []
          end
        else []
        end
      end

      def function_findings(name, change)
        return [] if change.kind == 'added'

        kind  = (change.kind == 'removed') ? 'function-removed' : 'function-changed'
        sites = @evidence&.call_sites(change.name)
        [make(name, kind, change.name, (sites.nil? || sites.empty?) ? [] : [list('sites', sites)], change)]
      end

      def type_findings(name, change, _to)
        type = change.name
        case change.kind
        when 'removed'
          [make(name, 'type-removed', type, resources(@evidence&.resources(type)), change)]
        when 'changed'
          attribute, what = param_change(change)
          return [] unless attribute && %i[removed type default values].include?(what)

          kind = (what == :removed) ? 'type-attribute-removed' : 'type-attribute-changed'
          [make(name, kind, "#{type} #{attribute}", resources(@evidence&.resources(type, with: attribute)), change)]
        else []
        end
      end

      def provider_findings(name, change)
        return [] unless change.kind == 'removed'

        type, provider = change.name.split('/', 2)
        [make(name, 'provider-removed', change.name, nodes(@evidence&.naming(type, provider)), change)]
      end

      def fact_findings(name, change)
        return [] unless change.kind == 'removed'

        [make(name, 'fact-removed', change.name, nodes(@evidence&.reading(change.name)), change)]
      end

      def alias_findings(name, change)
        return [] if change.kind == 'added'

        kind = (change.kind == 'removed') ? 'type-alias-removed' : 'type-alias-changed'
        [make(name, kind, change.name, nodes(@evidence&.using_alias(change.name)), change)]
      end

      # @return [Array(String, Symbol), nil] the parameter a change is about
      #   and what happened: :removed, :added, :type, :default, :values, or :other
      def param_change(change)
        path = change.path
        return nil unless path.first == 'params' && path.size >= 2

        param = path[1]
        what =
          if path.size == 2 then change.old.nil? ? :added : :removed
          elsif path[2] == 'type' then :type
          elsif path[2] == 'default' then :default
          elsif path[2] == 'values' then :values
          else :other
          end
        [param, what]
      end

      def required?(param)
        param.is_a?(Hash) && !param.key?('default') && !param['captures_rest']
      end

      # @param uses [Array<Use>] none without evidence means the use is
      #   unknown, none with it means no use
      def make(name, kind, subject, uses, change)
        Finding.new(module: name, kind: kind, subject: subject, uses: (uses.empty? && @evidence.nil?) ? nil : uses,
                    detail: "#{Surface::Render.difference(change)}: #{Surface::Render.detail(change)}")
      end

      # @return [Array<Use>] one "nodes" use, or none
      def nodes(certnames)
        return [] if certnames.nil? || certnames.empty?

        [list('nodes', certnames.map { |c| Item.new(name: nil, certname: c) })]
      end

      def resources(pairs)
        return [] if pairs.nil? || pairs.empty?

        [list('resources', pairs.map { |certname, r| Item.new(name: "#{r['type']}[#{r['title']}]", certname: certname) })]
      end

      # @return [Array<String>] one "hiera: ..." part naming the data files
      #   setting the key, or none
      def hiera(key)
        refs = @hiera[key]
        (refs.nil? || refs.empty?) ? [] : [list('hiera', refs)]
      end

      # The data files setting any key of the class.
      def hiera_under(klass)
        refs = @hiera.select { |key, _| key.start_with?("#{klass}::") }.values.flatten
        refs.empty? ? [] : [list('hiera', refs)]
      end

      # @param items [Array<Item, String>] a String is a file:line
      def list(label, items)
        items = items.map { |i| i.is_a?(Item) ? i : Item.new(name: i, certname: nil) }.uniq
        Use.new(label: label, items: items.first(NAMED), more: [items.size - NAMED, 0].max)
      end
    end
  end
end
