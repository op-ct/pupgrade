module Pupgrade
  module Compile
    # At what level each node's mocked answers are logged: rules from
    # `--on-mock`, each a level with an optional filter on the certname or
    # a fact, the last matching rule deciding, so one node or one OS can be
    # traced in a full run.
    #
    #     --on-mock=debug                              every node
    #     --on-mock='certname=web*,db01*:info'         those nodes
    #     --on-mock='facts.os.family=RedHat:notice'    nodes with that fact
    #     --on-mock='certname=web*;facts.os.name=Rocky:trace'   both
    class OnMock
      class Error < StandardError; end

      LEVELS  = %w[silent trace debug info notice warning].freeze
      DEFAULT = 'debug'.freeze

      # One rule: the level, and what a node must match for it.
      #
      # @!attribute [r] level
      #   @return [String] one of {LEVELS}
      # @!attribute [r] certnames
      #   @return [Array<String>] globs; empty for any node
      # @!attribute [r] facts
      #   @return [Hash{String => Array<String>}] a dotted fact path to the
      #     values (globs) any of which matches; empty for any node
      Rule = Data.define(:level, :certnames, :facts) do
        def matches?(factset)
          certnames.empty? || certnames.any? { |g| File.fnmatch?(g, factset.certname, File::FNM_CASEFOLD) } and
            facts.all? { |path, values| values.any? { |v| File.fnmatch?(v, dig(factset.values, path).to_s, File::FNM_CASEFOLD) } }
        end

        def dig(hash, path)
          path.split('.').reduce(hash) { |node, part| node.is_a?(Hash) ? node[part] : nil }
        end
      end

      # @param texts [Array<String>, String, nil] `[FILTER:]LEVEL` each
      # @return [OnMock]
      # @raise [Error]
      def self.parse(texts)
        new(Array(texts).map { |t| rule(t.to_s) })
      end

      # @param text [String] "LEVEL", "certname=GLOB[,GLOB]:LEVEL",
      #   "facts.a.b=VALUE[,VALUE]:LEVEL", filters joined by ";"
      # @return [Rule]
      def self.rule(text)
        filter, level = text.include?(':') ? text.split(':', 2).then { |f, l| [f, l] } : [nil, text]
        raise Error, "on-mock level must be one of #{LEVELS.join(', ')}, got #{level.inspect}" unless LEVELS.include?(level)

        certnames = []
        facts     = {}
        filter.to_s.split(';').reject(&:empty?).each do |part|
          key, values = part.split('=', 2)
          raise Error, "on-mock filter #{part.inspect}: expected certname=GLOB or facts.PATH=VALUE" if values.nil? || values.empty?

          if key == 'certname'
            certnames.concat(values.split(','))
          elsif key.start_with?('facts.') && key.size > 6
            facts[key.delete_prefix('facts.')] = values.split(',')
          else
            raise Error, "on-mock filter #{part.inspect}: expected certname=GLOB or facts.PATH=VALUE"
          end
        end
        Rule.new(level: level, certnames: certnames, facts: facts)
      end

      # @param rules [Array<Rule>]
      def initialize(rules)
        @rules = rules
      end

      # @return [Array<Rule>]
      attr_reader :rules

      # The level for a node: the last rule matching it, else {DEFAULT}.
      def level_for(factset)
        @rules.reverse.find { |r| r.matches?(factset) }&.level || DEFAULT
      end

      def to_s
        @rules.map { |r| [r.certnames.empty? ? nil : "certname=#{r.certnames.join(',')}", *r.facts.map { |p, v| "facts.#{p}=#{v.join(',')}" }, r.level].compact.join(':') }.join(' ')
      end
    end
  end
end
