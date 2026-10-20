require 'pupgrade/surface/diff'

module Pupgrade
  module Impact
    # Turns the surface changes of one module into findings about the site:
    # each change the evidence shows the site touching, and where. Without
    # evidence every change is a finding with its use unknown.
    class Analysis
      KINDS = %w[
        class-removed class-param-removed class-param-added-required class-param-type-changed class-param-default-changed
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
      # @!attribute [r] where
      #   @return [String] the nodes, resources, call sites, or Hiera keys
      #     concerned; "use unknown" without evidence; "" when nothing uses it
      # @!attribute [r] detail
      #   @return [String] the surface change
      Finding = Data.define(:module, :kind, :subject, :where, :detail) do
        # Whether the evidence shows the site touching it; a use unknown or
        # not tracked is neither a use nor its absence.
        def used?
          !where.empty? && !UNKNOWN.include?(where)
        end
      end

      UNKNOWN = ['use unknown', 'use not tracked'].freeze

      # How many names a `where` lists before counting instead.
      NAMED = 3

      # @param evidence [Evidence, nil]
      # @param hiera [Hash{String => Array<String>}] "class::param" or class
      #   name to the Hiera keys and lookups referring to it that the
      #   proposed schema no longer answers, as "path:line"
      def initialize(evidence: nil, hiera: {})
        @evidence = evidence
        @hiera    = hiera
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
          [make(name, 'class-removed', klass, nodes(@evidence&.including(klass)) + hiera(klass), change.detail)]
        when 'changed'
          param, what = param_change(change.detail)
          return [] unless param

          case what
          when :removed
            [make(name, 'class-param-removed', "#{klass}::#{param}", nodes(@evidence&.setting(klass, param)) + hiera("#{klass}::#{param}"), change.detail)]
          when :added
            return [] unless required?(to.dig('classes', klass, 'params', param))

            [make(name, 'class-param-added-required', "#{klass}::#{param}", nodes(@evidence&.including(klass)), change.detail)]
          when :type
            [make(name, 'class-param-type-changed', "#{klass}::#{param}", nodes(@evidence&.setting(klass, param)) + hiera("#{klass}::#{param}"), change.detail)]
          when :default
            [make(name, 'class-param-default-changed', "#{klass}::#{param}", nodes(@evidence&.defaulting(klass, param)), change.detail)]
          else []
          end
        else []
        end
      end

      def define_findings(name, change, to)
        type = change.name
        case change.kind
        when 'removed'
          [make(name, 'define-removed', type, resources(@evidence&.resources(type)), change.detail)]
        when 'changed'
          param, what = param_change(change.detail)
          return [] unless param

          case what
          when :removed
            [make(name, 'define-param-removed', "#{type} #{param}", resources(@evidence&.resources(type, with: param)), change.detail)]
          when :added
            return [] unless required?(to.dig('defined_types', type, 'params', param))

            lacking = @evidence&.resources(type)&.reject { |_, r| r['parameters'].key?(param) }
            [make(name, 'define-param-added-required', "#{type} #{param}", resources(lacking), change.detail)]
          when :type
            [make(name, 'define-param-type-changed', "#{type} #{param}", resources(@evidence&.resources(type, with: param)), change.detail)]
          when :default
            defaulting = @evidence&.resources(type)&.reject { |_, r| r['parameters'].key?(param) }
            [make(name, 'define-param-default-changed', "#{type} #{param}", resources(defaulting), change.detail)]
          else []
          end
        else []
        end
      end

      def function_findings(name, change)
        return [] if change.kind == 'added'

        kind  = (change.kind == 'removed') ? 'function-removed' : 'function-changed'
        sites = @evidence&.call_sites(change.name)
        [make(name, kind, change.name, sites.nil? ? nil : list('sites', sites), change.detail)]
      end

      def type_findings(name, change, _to)
        type = change.name
        case change.kind
        when 'removed'
          [make(name, 'type-removed', type, resources(@evidence&.resources(type)), change.detail)]
        when 'changed'
          attribute, what = param_change(change.detail)
          return [] unless attribute && %i[removed type default values].include?(what)

          kind = (what == :removed) ? 'type-attribute-removed' : 'type-attribute-changed'
          [make(name, kind, "#{type} #{attribute}", resources(@evidence&.resources(type, with: attribute)), change.detail)]
        else []
        end
      end

      def provider_findings(name, change)
        return [] unless change.kind == 'removed'

        type, provider = change.name.split('/', 2)
        [make(name, 'provider-removed', change.name, nodes(@evidence&.naming(type, provider)), change.detail)]
      end

      def fact_findings(name, change)
        return [] unless change.kind == 'removed'

        [make(name, 'fact-removed', change.name, nodes(@evidence&.reading(change.name)), change.detail)]
      end

      def alias_findings(name, change)
        return [] if change.kind == 'added'

        kind = (change.kind == 'removed') ? 'type-alias-removed' : 'type-alias-changed'
        [Finding.new(module: name, kind: kind, subject: change.name, where: 'use not tracked', detail: change.detail)]
      end

      # @return [Array(String, Symbol), nil] the parameter a detail is about
      #   and what happened: :removed, :added, :type, :default, :values, or :other
      def param_change(detail)
        m = detail.match(/\Aparams\.([^.:]+)(?:\.([^:]+))?: (added|removed)?/)
        return nil unless m

        param, attribute, verb = m.captures
        what =
          if attribute.nil? then (verb == 'added') ? :added : :removed
          elsif attribute == 'type' then :type
          elsif attribute == 'default' then :default
          elsif attribute == 'values' then :values
          else :other
          end
        [param, what]
      end

      def required?(param)
        param.is_a?(Hash) && !param.key?('default') && !param['captures_rest']
      end

      def make(name, kind, subject, where, detail)
        where = where.nil? ? 'use unknown' : where.reject(&:empty?).join('; ') if where.nil? || where.is_a?(Array)
        Finding.new(module: name, kind: kind, subject: subject, where: where.to_s, detail: detail)
      end

      # @return [Array<String>] one "nodes: ..." part, or none
      def nodes(certnames)
        return [] if certnames.nil? || certnames.empty?

        [list('nodes', certnames)]
      end

      def resources(pairs)
        return [] if pairs.nil? || pairs.empty?

        names = pairs.map { |certname, r| "#{r['type']}[#{r['title']}] on #{certname}" }
        [list('resources', names)]
      end

      def hiera(key)
        refs = @hiera[key]
        (refs.nil? || refs.empty?) ? [] : [list('hiera', refs)]
      end

      def list(label, names)
        names = names.uniq
        shown = (names.size <= NAMED) ? names.join(', ') : "#{names.first(NAMED).join(', ')} and #{names.size - NAMED} more"
        "#{label}: #{shown}"
      end
    end
  end
end
