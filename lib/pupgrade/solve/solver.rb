require 'semantic_puppet'

require 'driftless/inputs/module_metadata'
require 'driftless/module_inventory'
require 'pupgrade/exclusions'
require 'pupgrade/module_name'
require 'pupgrade/module_resolver'
require 'pupgrade/solve/candidates'

module Pupgrade
  module Solve
    # Picks a version for every module. Modules are decided in dependency
    # order, dependencies before dependents, each at the first candidate in
    # the chosen order that satisfies every constraint against what is
    # already decided: its dependency ranges, the Puppet requirement, and
    # the operating systems of interest. A module with no such candidate is
    # held at the one with the fewest violations, which are reported.
    class Solver
      ORDERS = %w[newest oldest].freeze

      # One module's outcome.
      #
      # @!attribute [r] entry
      #   @return [Driftless::ModuleInventory::Entry]
      # @!attribute [r] candidates
      #   @return [Array<Candidates::Candidate>] considered, oldest first
      # @!attribute [r] chosen
      #   @return [Candidates::Candidate]
      # @!attribute [r] violations
      #   @return [Array<String>] the constraints the choice breaks
      # @!attribute [r] note
      #   @return [String] why this candidate: "newest", "first fit", "current",
      #     "bumped"; "held" when a newer candidate was blocked by the
      #     violations; "unresolved" when every candidate at least as new
      #     breaks the same constraints, so the choice went as far as it could
      Choice = Data.define(:entry, :candidates, :chosen, :violations, :note) do
        def moved?
          !chosen.current
        end

        # A better candidate was blocked: what the exit status reports.
        def held?
          note == 'held'
        end

        def unresolved?
          note.start_with?('unresolved')
        end

        def name
          entry.declared&.name || entry.metadata.name || File.basename(entry.path)
        end
      end

      # The result of a solve.
      #
      # @!attribute [r] choices
      #   @return [Array<Choice>] in the order decided
      # @!attribute [r] pruned
      #   @return [Array<String>] "module:dependency" edges the result
      #     violates among those pruned as unused; the exclusions to record
      # @!attribute [r] implicit
      #   @return [Array<String>] "module -> dependency" uses the evidence
      #     shows that no metadata declares
      Plan = Data.define(:choices, :pruned, :implicit)

      # @param operatingsystems [Hash] `modules.operatingsystems`
      # @param requirements [Hash] `modules.requirements`
      # @param exclude [Hash] the `modules.exclude_*` globs
      # @param order [String] one of {ORDERS}
      # @param bumps [Hash{String => String, nil}] modules to move, by
      #   normalized name, to a ref or to their newest candidate
      # @param holds [Array<String>] modules kept at their current version
      # @param evidence [Evidence, nil] what the site uses; with
      #   prune_unused, dependency edges to modules it shows unused are not
      #   constraints
      # @param prune_unused [Boolean]
      def initialize(operatingsystems: {}, requirements: {}, exclude: {}, order: 'newest', bumps: {}, holds: [],
                     evidence: nil, prune_unused: false)
        raise ArgumentError, "order must be one of #{ORDERS.join(', ')}" unless ORDERS.include?(order)
        raise ArgumentError, '--prune-unused needs evidence' if prune_unused && evidence.nil?

        @operatingsystems = (operatingsystems || {}).to_h { |os, rel| [os.to_s, Array(rel).map(&:to_s)] }
        @exclude   = (exclude || {}).to_h { |list, globs| [list.to_s, Array(globs).map(&:to_s)] }
        @site      = ModuleResolver.new(requirements: requirements).instance_variable_get(:@site_range)
        @order     = order
        @bumps     = bumps.to_h { |k, v| [k.to_s, v] }
        @holds     = holds.map(&:to_s)
        @evidence  = evidence
        @prune     = prune_unused
      end

      # @param entries [Array<Driftless::ModuleInventory::Entry>]
      # @param candidates [Hash{String => Array<Candidate>, Unsolvable}] by entry path
      # @return [Plan]
      def solve(entries, candidates)
        entries   = entries.select { |e| e.metadata.name && e.metadata.error.nil? && !excluded_module?(e.metadata.name) }
        by_name   = entries.to_h { |e| [normalize(e.metadata.name), e] }
        decided   = {}
        choices   = []
        pruned    = []
        ordered(entries, by_name).each do |entry|
          list = candidates.fetch(entry.path) { Candidates::Unsolvable.new(reason: 'no candidates') }
          choice = decide(entry, list, by_name, decided)
          decided[normalize(entry.metadata.name)] = choice.chosen.version
          choices << choice
          pruned.concat(pruned_edges(entry, choice.chosen, by_name, decided))
        end
        Plan.new(choices: choices, pruned: pruned.uniq, implicit: implicit(entries, by_name))
      end

      private

      def decide(entry, list, by_name, decided)
        name = normalize(entry.metadata.name)
        if list.is_a?(Candidates::Unsolvable)
          current = Candidates::Candidate.new(ref: entry.declared&.ref.to_s, ref_type: entry.declared&.ref_type || 'ref',
                                              version: parse(entry.metadata.version), metadata: entry.metadata, current: true)
          broken  = violations(entry, current, by_name, decided)
          return Choice.new(entry: entry, candidates: [current], chosen: current, violations: broken,
                            note: broken.empty? ? list.reason : "unresolved (#{list.reason})")
        end

        considered = ordered_candidates(entry, list, name)
        scored = considered.map { |c| [c, violations(entry, c, by_name, decided)] }
        fit = scored.find { |_, v| v.empty? }
        if fit
          note = note_for(entry, fit.first, name, considered)
          return Choice.new(entry: entry, candidates: list, chosen: fit.first, violations: [], note: note)
        end

        # Among equally broken candidates, staying put beats moving. The
        # choice is held when a newer candidate exists that the violations
        # kept it from; unresolved when it is the newest there is.
        best = scored.min_by.with_index { |(c, v), i| [v.size, c.current ? 0 : 1, i] }
        newer = list.any? { |c| c.version && best.first.version && c.version > best.first.version }
        Choice.new(entry: entry, candidates: list, chosen: best.first, violations: best.last, note: newer ? 'held' : 'unresolved')
      end

      # The candidates in the order they are tried: newest first, or from the
      # current version forward; a bump narrows them to its ref or the
      # newest; a hold to the current one.
      def ordered_candidates(_entry, list, name)
        return list.select(&:current) if held_by_hand?(name)

        if (bump = bump_for(name))
          target = bump.last
          return [list.max_by { |c| [c.version || SemanticPuppet::Version.parse('0.0.0'), c.current ? 0 : 1] }] if target.nil?

          wanted = list.find { |c| [target, "v#{target}"].include?(c.ref) || c.version.to_s == target.sub(/\Av/, '') }
          return [wanted] if wanted
        end
        (@order == 'newest') ? list.reverse : list
      end

      # --hold and --bump name modules by any spelling.
      def held_by_hand?(name)
        ModuleName.any?(@holds, name)
      end

      # @return [Array(String, String|nil), nil] the bump glob and its ref
      def bump_for(name)
        @bumps.find { |glob, _| ModuleName.match?(glob, name) }
      end

      def note_for(_entry, chosen, name, considered)
        return 'held at current' if held_by_hand?(name)
        return 'bumped' if bump_for(name)
        return 'current' if chosen.current

        (chosen.equal?(considered.first) && @order == 'newest') ? 'newest' : 'first fit'
      end

      # The constraints a candidate breaks against what is decided so far,
      # or the current versions of what is not.
      def violations(entry, candidate, by_name, decided)
        metadata = candidate.metadata
        out = []
        metadata.dependencies.each do |dep, requirement|
          dep_name = normalize(dep)
          target = by_name[dep_name]
          next if excluded_module?(dep) || Exclusions.dependency?(@exclude['dependencies'], [entry.metadata.name], [dep], requirement).first
          # a module nobody deployed is used by nobody
          next if @prune && (target.nil? || !used?(target))

          if target.nil?
            out << "needs #{dep} #{requirement || '(any version)'}; not on the modulepath"
            next
          end
          range = range_for(requirement)
          version = decided.fetch(dep_name) { parse(target.metadata.version) }
          next if range.nil? || version.nil? || range.include?(version)

          out << "needs #{dep} #{requirement}; #{target.path} would be #{version}"
        end
        puppet = puppet_range(metadata)
        if puppet && @site && puppet.intersection(@site) == ModuleResolver::EMPTY && !Exclusions.requirement?(@exclude['requirements'], entry.metadata.name)
          out << "requires puppet #{puppet}; the control repo requires #{@site}"
        end
        out.concat(os_violations(entry, metadata))
        out
      end

      def os_violations(entry, metadata)
        support = metadata.operatingsystem_support
        return [] if @operatingsystems.empty? || support.empty?

        @operatingsystems.flat_map do |os, releases|
          declared = support.find { |n, _| n.casecmp?(os) }&.last
          (releases.empty? ? [nil] : releases).filter_map { |release|
            subject = [os, release].compact.join(' ')
            next if Exclusions.operatingsystem?(@exclude['operatingsystems'], [entry.metadata.name], subject)

            if declared.nil?
              "missing #{os}"
            elsif release && !declared.empty? && declared.none? { |d| d == release || release.start_with?("#{d}.") }
              "missing #{subject}"
            end
          }.uniq
        end
      end

      # The pruned dependency edges the chosen version violates: what to
      # record as exclusions so `check` agrees with the plan.
      def pruned_edges(entry, chosen, by_name, decided)
        return [] unless @prune

        chosen.metadata.dependencies.filter_map do |dep, requirement|
          target = by_name[normalize(dep)]
          next if target.nil? || used?(target)

          range   = range_for(requirement)
          version = decided.fetch(normalize(dep)) { parse(target.metadata.version) }
          "#{entry.metadata.name}:#{dep}" if range && version && !range.include?(version)
        end
      end

      # Modules in dependency order: a module after everything its current
      # metadata depends on; a cycle's members follow by name.
      def ordered(entries, _by_name)
        remaining = entries.to_h { |e| [normalize(e.metadata.name), e] }
        deps_of   = remaining.to_h { |n, e| [n, e.metadata.dependencies.keys.map { |d| normalize(d) }.select { |d| remaining.key?(d) && d != n }] }
        order = []
        until remaining.empty?
          ready = remaining.keys.select { |n| deps_of[n].none? { |d| remaining.key?(d) } }.sort
          ready = [remaining.keys.min] if ready.empty?
          ready.each { |n| order << remaining.delete(n) }
        end
        order
      end

      # Functions the evidence shows one module calling from another that
      # the caller's metadata does not depend on.
      def implicit(entries, _by_name)
        return [] unless @evidence

        by_base = entries.to_h { |e| [File.basename(e.path), e] }
        @evidence.calls.flat_map { |user, providers|
          entry = by_base[user]
          next [] unless entry

          declared = entry.metadata.dependencies.keys.map { |d| normalize(d).split('-').last }
          providers.sort.filter_map { |p| "#{entry.metadata.name} -> #{p}" unless declared.include?(p) || p == user }
        }.sort
      end

      def used?(entry)
        return true if entry.nil? || @evidence.nil?

        @evidence.used?(File.basename(entry.path))
      end

      def puppet_range(metadata)
        declared = metadata.requirements.values_at(*::Driftless::Inputs::ModuleMetadata::PUPPET_REQUIREMENT_NAMES).compact
        parsed   = declared.filter_map { |r| range_for(r) }
        parsed.empty? ? nil : parsed.reduce { |a, b| a.intersection(b) }
      end

      def range_for(requirement)
        return ModuleResolver::ALL if requirement.nil? || requirement.strip.empty?

        SemanticPuppet::VersionRange.parse(requirement)
      rescue ArgumentError
        nil
      end

      def parse(version)
        SemanticPuppet::Version.parse(version.to_s)
      rescue SemanticPuppet::Version::ValidationFailure
        nil
      end

      def excluded_module?(name)
        Exclusions.module?(@exclude['modules'], name)
      end

      def normalize(name)
        name.to_s.tr('/', '-').downcase
      end
    end
  end
end
