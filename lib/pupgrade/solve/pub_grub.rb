require 'semantic_puppet'

module Pupgrade
  module Solve
    # The PubGrub version solver, from the `pub_grub` gem when it is
    # installed, else the copy Bundler vendors (Bundler 2.4 and later, so
    # every Ruby 3.2 and the Bolt AIO), and what pupgrade feeds it.
    module PubGrub
      LIB =
        begin
          require 'pub_grub'
          ::PubGrub
        rescue LoadError
          require 'bundler'
          require 'bundler/vendor/pub_grub/lib/pub_grub'
          ::Bundler::PubGrub
        end

      module_function

      # A PubGrub range for a SemanticPuppet one: a union of one range per
      # part, an open end as no maximum.
      #
      # @param range [SemanticPuppet::VersionRange, nil] nil for any version
      # @return [LIB::VersionRange, LIB::VersionUnion]
      def range(range)
        return LIB::VersionRange.any if range.nil?

        LIB::VersionUnion.union(range.ranges.map do |r|
          min = r.begin.to_s.start_with?('0.0.0-') ? nil : r.begin
          max = r.end.to_s.start_with?('Infinity') ? nil : r.end
          LIB::VersionRange.new(min: min, max: max, include_min: !min.nil? && !r.exclude_begin?, include_max: !r.exclude_end?)
        end)
      end

      # Every version but one.
      def except(version)
        LIB::VersionUnion.union([LIB::VersionRange.new(max: version, include_max: false),
                                 LIB::VersionRange.new(min: version, include_min: false)])
      end

      # Every version up to and including one.
      def up_to(version)
        LIB::VersionRange.new(max: version, include_max: true)
      end

      # The incompatibilities a failure was derived from: each a dependency
      # of one package version on another, a fact pupgrade stated, or the
      # absence of any version.
      #
      # @param incompatibility [LIB::Incompatibility]
      # @return [Array<LIB::Incompatibility>]
      def leaves(incompatibility)
        return [incompatibility] unless incompatibility.conflict?

        leaves(incompatibility.cause.conflict) + leaves(incompatibility.cause.other)
      end

      # One thing pupgrade tells the solver outright: a version a package
      # must not be, or must be, with the words that explain it.
      #
      # @!attribute [r] package
      #   @return [String]
      # @!attribute [r] range
      #   @return [LIB::VersionRange, LIB::VersionUnion] the versions ruled out
      # @!attribute [r] text
      #   @return [String] "stdlib is held at 8.6.0 (--hold)"
      Fact = Data.define(:package, :range, :text)

      # What the solver asks pupgrade about the packages: the versions of
      # each, what each version depends on, and the reasons a version
      # cannot be used at all. Packages are module short names; versions
      # are `SemanticPuppet::Version`.
      class Source < LIB::BasicPackageSource
        # The leaf incompatibilities this source produced, by object:
        # [package, key, text], where key names the constraint (the
        # dependency's package, "puppet", or "os RedHat") so the solver
        # can be told to drop it.
        #
        # @return [Hash{LIB::Incompatibility => Array}]
        attr_reader :keys

        # @param versions [Hash{String => Array<SemanticPuppet::Version>}] by
        #   package, in the order preferred
        # @param dependencies [#call] (package, version) -> {package => SemanticPuppet::VersionRange|nil}
        # @param reasons [#call] (package, version) -> [[key, text], ...] why
        #   that version cannot be used
        # @param facts [Array<Fact>]
        def initialize(versions:, dependencies:, reasons:, facts:)
          @versions     = versions
          @packages     = versions # the vendored source reads this name
          @dependencies = dependencies
          @reasons      = reasons
          @facts        = facts
          @keys         = {}
          super()
        end

        def all_versions_for(package)
          @versions.fetch(package) { [] }
        end

        def sort_versions_by_preferred(package, sorted)
          order = @versions.fetch(package) { [] }
          sorted.sort_by { |v| order.index(v) || sorted.size }
        end

        def dependencies_for(package, version)
          @dependencies.call(package, version)
        end

        def parse_dependency(_package, range)
          PubGrub.range(range)
        end

        def root_dependencies
          @versions.keys.to_h { |k| [k, nil] }
        end

        # The dependency incompatibilities PubGrub derives, keyed; at the
        # root the facts; for a version the reasons it cannot be used.
        def incompatibilities_for(package, version)
          list = super
          if LIB::Package.root?(package)
            @facts.each do |fact|
              list << LIB::Incompatibility.new([LIB::Term.new(LIB::VersionConstraint.new(fact.package, range: fact.range), true)],
                                               cause: LIB::Incompatibility::NoVersions.new(nil), custom_explanation: fact.text)
            end
            return list
          end

          list.each { |inc| @keys[inc] = [package, inc.terms[1].package, inc.to_s] if inc.cause == :dependency }
          @reasons.call(package, version).each do |key, text|
            inc = LIB::Incompatibility.new([LIB::Term.new(LIB::VersionConstraint.exact(package, version), true)],
                                           cause: LIB::Incompatibility::NoVersions.new(nil), custom_explanation: text)
            @keys[inc] = [package, key, text]
            list << inc
          end
          list
        end
      end

      # @param source [Source]
      # @return [Array(Hash{String => SemanticPuppet::Version}|nil, LIB::SolveFailure|nil)]
      #   the versions decided, or the failure
      def solve(source)
        solver = LIB::VersionSolver.new(source: source, logger: Logger.new(IO::NULL))
        [solver.solve.reject { |pkg, _| LIB::Package.root?(pkg) }, nil]
      rescue LIB::SolveFailure => e
        [nil, e]
      end
    end
  end
end
