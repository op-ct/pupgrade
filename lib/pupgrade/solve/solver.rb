require 'semantic_puppet'

require 'driftless/inputs/module_metadata'
require 'driftless/module_inventory'
require 'pupgrade/exclusions'
require 'pupgrade/logging'
require 'pupgrade/module_name'
require 'pupgrade/module_resolver'
require 'pupgrade/solve/candidates'

module Pupgrade
  module Solve
    # Picks a version for every module. Modules are decided in dependency
    # order, dependencies before dependents, each at the first candidate in
    # the chosen order that satisfies every constraint against what is
    # already decided: its dependency ranges, the Puppet requirement, and
    # the operating systems of interest. A module with no such candidate
    # stays at the one with the fewest violations, which are reported along
    # with what blocked the newest candidate.
    class Solver
      ORDERS = %w[newest oldest].freeze

      # One constraint a candidate breaks: what it asks, and what stands in
      # the way.
      #
      # @!attribute [r] text
      #   @return [String] "needs puppetlabs/stdlib >= 9.0.0 < 10.0.0"
      # @!attribute [r] fault
      #   @return [String] "stdlib is 8.6.0", "stdlib moves to 10.0.0",
      #     "zookeeper is not on the modulepath", "missing RedHat 9"
      Violation = Data.define(:text, :fault) do
        def to_s
          "#{text}, but #{fault}"
        end
      end

      # One module's outcome.
      #
      # @!attribute [r] entry
      #   @return [Driftless::ModuleInventory::Entry]
      # @!attribute [r] candidates
      #   @return [Array<Candidates::Candidate>] oldest first, the current
      #     version first of all
      # @!attribute [r] verdicts
      #   @return [Array<Array(Candidates::Candidate, Array<Violation>)>] every
      #     candidate with the constraints it breaks, in candidate order
      # @!attribute [r] chosen
      #   @return [Candidates::Candidate]
      # @!attribute [r] violations
      #   @return [Array<Violation>] the constraints the choice breaks
      # @!attribute [r] blocked
      #   @return [Array(Candidates::Candidate, Array<Violation>), nil] the
      #     newest candidate the choice could not move to, and why
      # @!attribute [r] note
      #   @return [String] why this candidate: "newest", "first fit", "current",
      #     "bumped", "held at current"; "held" when a newer candidate was
      #     blocked by its violations; "unresolved" when the choice is the
      #     newest there is and still breaks something
      Choice = Data.define(:entry, :candidates, :verdicts, :chosen, :violations, :blocked, :note) do
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
      # @!attribute [r] warnings
      #   @return [Array<String>] bumps and holds that matched nothing, bump
      #     refs that are not candidates
      Plan = Data.define(:choices, :pruned, :implicit, :warnings)

      # @param operatingsystems [Hash] `modules.operatingsystems`
      # @param requirements [Hash] `modules.requirements`
      # @param exclude [Hash] the `modules.exclude_*` globs
      # @param order [String] one of {ORDERS}
      # @param bumps [Hash{String => String, nil}] modules to move, by any
      #   spelling of the name, to a ref or to their newest candidate
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
        by_name   = index(entries)
        decided   = {}
        choices   = []
        pruned    = []
        @warnings = []
        @matched  = { bump: [], hold: [] }
        ordered(entries, by_name).each do |entry|
          list = candidates.fetch(entry.path) { Candidates::Unsolvable.new(reason: 'no candidates') }
          choice = decide(entry, list, by_name, decided)
          decided[key(entry.metadata.name)] = choice.chosen.version
          choices << choice
          pruned.concat(pruned_edges(entry, choice.chosen, by_name, decided))
          Pupgrade.logger.info("solve: #{choice.name}: #{choice.chosen} (#{choice.note})")
        end
        unmatched_levers
        Plan.new(choices: choices, pruned: pruned.uniq, implicit: implicit(entries, by_name), warnings: @warnings)
      end

      private

      # Modules by short name: owners differ between a dependent's metadata
      # and the module's own (`voxpupuli/firewalld` for `puppet-firewalld`),
      # and a modulepath holds one module of a name. Two deployed modules
      # sharing a short name is a warning; the first by path wins.
      def index(entries)
        entries.sort_by(&:path).each_with_object({}) do |e, h|
          k = key(e.metadata.name)
          if h.key?(k)
            Pupgrade.logger.warn("solve: #{e.path} and #{h[k].path} are both #{k}; only #{h[k].path} is considered")
            next
          end
          h[k] = e
        end
      end

      def decide(entry, list, by_name, decided)
        if list.is_a?(Candidates::Unsolvable)
          current = Candidates::Candidate.new(ref: entry.declared&.ref.to_s, ref_type: entry.declared&.ref_type || 'ref',
                                              version: parse(entry.metadata.version), metadata: entry.metadata, current: true)
          broken  = violations(entry, current, by_name, decided)
          return Choice.new(entry: entry, candidates: [current], verdicts: [[current, broken]], chosen: current, violations: broken,
                            blocked: nil, note: broken.empty? ? list.reason : "unresolved (#{list.reason})")
        end

        verdicts = list.map { |c| [c, violations(entry, c, by_name, decided)] }
        verdicts.each { |c, v| Pupgrade.logger.debug("solve: #{entry.path}: #{c}: #{v.empty? ? 'fits' : v.join('; ')}") }
        considered, bump = ordered_candidates(entry, list, verdicts)
        scored = verdicts.select { |c, _| considered.include?(c) }.sort_by { |c, _| considered.index(c) }
        fit = scored.find { |_, v| v.empty? }
        if fit
          note = note_for(entry, fit.first, bump, considered)
          return Choice.new(entry: entry, candidates: list, verdicts: verdicts, chosen: fit.first, violations: [], blocked: nil, note: note)
        end

        # A hold or a bump decides the candidate whatever it breaks; the
        # note says so and the violations are shown. Otherwise, among
        # equally broken candidates staying put beats moving: the choice is
        # held when a newer candidate exists that its own violations kept it
        # from, and those are what is reported; unresolved when the choice
        # is the newest there is.
        best = scored.min_by.with_index { |(c, v), i| [v.size, c.current ? 0 : 1, i] }
        if held_by_hand(entry.metadata.name) || bump
          return Choice.new(entry: entry, candidates: list, verdicts: verdicts, chosen: best.first, violations: best.last,
                            blocked: nil, note: bump ? 'bumped' : 'held at current')
        end

        newest = verdicts.reject { |c, _| c.equal?(best.first) }
          .select { |c, _| c.version && best.first.version && c.version > best.first.version }
          .max_by { |c, _| c.version }
        Choice.new(entry: entry, candidates: list, verdicts: verdicts, chosen: best.first, violations: best.last,
                   blocked: newest, note: newest ? 'held' : 'unresolved')
      end

      # The candidates in the order they are tried: newest first, or from the
      # current version forward; a bump narrows them to its ref or the
      # newest; a hold to the current one.
      #
      # @return [Array(Array<Candidate>, Array|nil)] the candidates and the
      #   bump in force, if any
      def ordered_candidates(entry, list, verdicts)
        name = entry.metadata.name
        if (hold = held_by_hand(name))
          @matched[:hold] << hold
          return [list.select(&:current), nil]
        end

        bump = bump_for(name)
        if bump
          @matched[:bump] << bump.first
          target = bump.last
          if target.nil? || target.empty?
            return [[list.max_by { |c| [c.version || SemanticPuppet::Version.parse('0.0.0'), c.current ? 0 : 1] }], bump]
          end

          wanted = list.find { |c| [target, "v#{target}"].include?(c.ref) || c.version.to_s == target.sub(/\Av/, '') }
          return [[wanted], bump] if wanted

          others = list.reject(&:current).map(&:ref).join(', ')
          @warnings << "--bump #{bump.first}=#{target}: #{target} is not a candidate of #{entry.path} " \
                       "(candidates: #{others.empty? ? 'none' : others}; try --fetch)"
          Pupgrade.logger.debug("solve: #{entry.path}: bump #{target} not among #{verdicts.size} candidate(s); ordering as usual")
          bump = nil
        end
        [(@order == 'newest') ? list.reverse : list, bump]
      end

      # @return [String, nil] the hold glob naming the module
      def held_by_hand(name)
        @holds.find { |g| ModuleName.match?(g, name) }
      end

      # @return [Array(String, String|nil), nil] the bump glob and its ref
      def bump_for(name)
        @bumps.find { |glob, _| ModuleName.match?(glob, name) }
      end

      def note_for(entry, chosen, bump, considered)
        return 'held at current' if held_by_hand(entry.metadata.name)
        return 'bumped' if bump
        return 'current' if chosen.current

        (chosen.equal?(considered.first) && @order == 'newest') ? 'newest' : 'first fit'
      end

      # A --bump or --hold that named no module is a typo or a module that is
      # not a git clone; either way the user should hear.
      def unmatched_levers
        (@bumps.keys - @matched[:bump]).each { |g| @warnings << "--bump #{g} matches no module" }
        (@holds - @matched[:hold]).each { |g| @warnings << "--hold #{g} matches no module" }
      end

      # The constraints a candidate breaks against what is decided so far,
      # or the current versions of what is not.
      #
      # @return [Array<Violation>]
      def violations(entry, candidate, by_name, decided)
        metadata = candidate.metadata
        out = []
        metadata.dependencies.each do |dep, requirement|
          dep_name = key(dep)
          target = by_name[dep_name]
          next if excluded_module?(dep) || Exclusions.dependency?(@exclude['dependencies'], [entry.metadata.name], [dep], requirement).first
          # a module nobody deployed is used by nobody
          next if @prune && (target.nil? || !used?(target))

          text = "needs #{dep} #{requirement || '(any version)'}"
          if target.nil?
            out << Violation.new(text: text, fault: "#{dep_name} is not on the modulepath")
            next
          end
          range    = range_for(requirement)
          deployed = parse(target.metadata.version)
          version  = decided.fetch(dep_name) { deployed }
          next if range.nil? || version.nil? || range.include?(version)

          fault = (version == deployed) ? "#{dep_name} is #{version}" : "#{dep_name} moves to #{version}"
          out << Violation.new(text: text, fault: fault)
        end
        puppet = puppet_range(metadata)
        if puppet && @site && puppet.intersection(@site) == ModuleResolver::EMPTY && !Exclusions.requirement?(@exclude['requirements'], entry.metadata.name)
          out << Violation.new(text: "requires puppet #{puppet}", fault: "the control repo requires #{@site}")
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
              Violation.new(text: "supports #{support.keys.join(', ')}", fault: "missing #{os}")
            elsif release && !declared.empty? && declared.none? { |d| d == release || release.start_with?("#{d}.") }
              Violation.new(text: "supports #{os} #{declared.join(', ')}", fault: "missing #{subject}")
            end
          }.uniq
        end
      end

      # The pruned dependency edges the chosen version violates: what to
      # record as exclusions so `check` agrees with the plan.
      def pruned_edges(entry, chosen, by_name, decided)
        return [] unless @prune

        chosen.metadata.dependencies.filter_map do |dep, requirement|
          target = by_name[key(dep)]
          next if target.nil? || used?(target)

          range   = range_for(requirement)
          version = decided.fetch(key(dep)) { parse(target.metadata.version) }
          "#{entry.metadata.name}:#{dep}" if range && version && !range.include?(version)
        end
      end

      # Modules in dependency order: a module after everything its current
      # metadata depends on; a cycle's members follow by name.
      def ordered(_entries, by_name)
        remaining = by_name.dup
        deps_of   = remaining.to_h { |n, e| [n, e.metadata.dependencies.keys.map { |d| key(d) }.select { |d| remaining.key?(d) && d != n }] }
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

          declared = entry.metadata.dependencies.keys.map { |d| key(d) }
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

      # The name modules are indexed by.
      def key(name)
        ModuleName.short(name)
      end
    end
  end
end
