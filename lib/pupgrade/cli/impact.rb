require 'json'

require 'pupgrade/cli/base'
require 'pupgrade/cli/root'
require 'pupgrade/cli/table'
require 'pupgrade/config_keys'
require 'driftless/codebase'
require 'driftless/control_repo'
require 'driftless/module_inventory'
require 'driftless/params_schema'
require 'driftless/params_schema/validate'
require 'pupgrade/module_proposal'
require 'pupgrade/surface'
require 'pupgrade/surface/diff'
require 'pupgrade/impact/analysis'
require 'pupgrade/impact/evidence'
require 'pupgrade/impact/history'

module Pupgrade
  module CLI
    # `pupgrade impact`
    #
    # What the site would feel from a proposed Puppetfile: for each module
    # it moves, the surface changes between the deployed version and the
    # proposed ref, each mapped to the nodes, resources, call sites, and
    # Hiera keys the evidence shows concerned. Exit 1 when any finding has
    # a use.
    class Impact < Base
      include Table
      extend ::Pupgrade::ConfigKeys::DSL

      register_command name: 'impact', subcommand_of: Root
      desc 'What a proposed Puppetfile would change for the site: surface changes mapped to their uses'

      config_key 'impact.evidence', type: :string, default: nil, example: 'pupgrade-catalogs',
                 about: 'A `compile` output directory whose probes and catalogs say what each node uses, relative to ' \
                        'the control repo; compile.output_dir when it exists and this is unset'

      COLUMNS         = %w[module impact subject where detail].freeze
      SUMMARY_COLUMNS = %w[module from to commits findings used].freeze

      def execute(argv)
        reject_extra_args!(argv)
        repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
        fatal!('impact requires --repo-dir (auto-detection did not supply it)', help: true) unless repo
        fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?
        fatal!('impact needs --propose PUPPETFILE', help: true) unless @options[:propose]
        check_kinds!

        inventory = ::Driftless::ModuleInventory.new(repo.dir)
        proposal  = ::Pupgrade::ModuleProposal.new(inventory, File.expand_path(@options[:propose], repo.dir))
        changes   = proposal.changes.select { |c| c.to && c.from }
        log_warnings(inventory.warnings + proposal.warnings)
        evidence  = load_evidence(repo)
        surfaces  = surfaces_for(repo, inventory, proposal, changes)
        hiera     = hiera_references(repo, inventory, surfaces)
        analysis  = ::Pupgrade::Impact::Analysis.new(evidence: evidence, hiera: hiera)

        modules  = []
        findings = []
        surfaces.each do |change, (from, to)|
          diff  = ::Pupgrade::Surface::Diff.documents(from, to)
          found = analysis.findings(change.name, diff, to)
          entry = inventory.entries.find { |e| e.path == change.path }
          history = ::Pupgrade::Impact::History.between(File.join(repo.dir, change.path), entry.declared.ref.to_s, proposed_ref(change),
                                                        from_version: from.dig('module', 'version'), to_version: to.dig('module', 'version'))
          modules << [change, history, found]
          findings.concat(found)
        end
        shown = findings.select { |f| shown?(f) }

        if @options[:summary]
          print_table(SUMMARY_COLUMNS, modules.map { |c, h, f| summary_row(c, h, f.select { |x| shown?(x) }) })
        else
          print_table(COLUMNS, shown.map { |f| [f.module, f.kind, f.subject, f.where, f.detail] })
          print_history(modules) if @options[:changelog] || @options[:gitlog]
        end
        ::Pupgrade.logger.info("impact: #{modules.size} module(s) move; #{shown.count(&:used?)} finding(s) with a use, " \
                               "#{shown.count { |f| !f.used? }} without#{' (no evidence; uses unknown)' unless evidence}")
        exit(shown.any?(&:used?) ? 1 : 0)
      rescue ::Pupgrade::ModuleProposal::Error, ::Pupgrade::Surface::Error, ::Pupgrade::Impact::Evidence::Error => e
        fatal!("impact: #{e.message}", 3)
      end

      protected

      def configure_parser(o)
        o.on('-d', '--repo-dir=DIR', 'Path to the control repo environment',
             "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
        o.on('--propose=PUPPETFILE', 'The proposed Puppetfile (what `solve -o` wrote, or an overlay of your own)') { |v| @options[:propose] = v }
        o.on('--evidence=DIR', 'A `compile` output directory (config: impact.evidence, else compile.output_dir)') { |v| @options[:evidence] = v }
        o.on('--no-evidence', 'Map nothing to nodes; every change is a finding with its use unknown') { @options[:no_evidence] = true }

        o.separator ''
        o.separator 'Row filters (comma-separated, repeatable; globs are case-insensitive):'
        o.on('--modules=GLOBS', Array, 'Only modules whose name matches') { |v| accumulate(:modules, v) }
        o.on('--impacts=KINDS', Array, "Only these kinds (#{::Pupgrade::Impact::Analysis::KINDS.join(', ')})") { |v| accumulate(:kinds, v) }
        o.on('--all', 'Show findings nothing uses too') { @options[:all] = true }

        o.separator ''
        o.separator 'Layout:'
        o.on('--summary', 'One row per moving module: refs, commits, findings') { @options[:summary] = true }
        o.on('--gitlog', 'After the table, each module\'s commits between the refs') { @options[:gitlog] = true }
        o.on('--changelog', 'After the table, each module\'s CHANGELOG sections for the versions crossed') { @options[:changelog] = true }

        o.separator ''
        o.separator 'Surfaces are read from the deployed module and from the proposed ref (through the'
        o.separator 'clone when it has the ref, else the remote). Exits 1 when any finding has a use.'
      end

      private

      def load_evidence(repo)
        return nil if @options[:no_evidence]

        dir = @options[:evidence]
        dir ||= @options[:output_dir] if @options[:output_dir] && File.directory?(File.expand_path(@options[:output_dir], repo.dir))
        return nil unless dir

        ::Pupgrade::Impact::Evidence.new(File.expand_path(dir, repo.dir))
      end

      # The current and proposed surface of every git module the proposal
      # moves, keyed by the change.
      #
      # @return [Hash{ModuleProposal::Change => Array(Hash, Hash)}]
      def surfaces_for(repo, inventory, proposal, changes)
        changes.filter_map { |change|
          entry    = inventory.entries.find { |e| e.path == change.path }
          proposed = proposal.entries.find { |e| e.path == change.path }
          next unless entry&.declared&.git && proposed&.declared&.git

          clone = File.join(repo.dir, change.path)
          ref   = proposed_ref(change)
          ::Pupgrade.logger.debug("impact: reading #{change.name} at #{entry.declared.ref} and #{ref}")
          from = ::Pupgrade::Surface.extract(clone)
          to   = surface_at(clone, proposed.declared.git, ref)
          [change, [from, to]]
        }.to_h
      end

      # The proposed surface, fetched from the clone when it already holds
      # the ref, else from the remote.
      def surface_at(clone, url, ref)
        source = ref_in?(clone, ref) ? clone : url
        ::Pupgrade::Surface.checkout(source, ref) { |dir| ::Pupgrade::Surface.extract(dir) }
      end

      def ref_in?(clone, ref)
        system('git', '-C', clone, 'rev-parse', '--verify', '--quiet', "#{ref}^{commit}", out: File::NULL, err: File::NULL)
      end

      def proposed_ref(change)
        change.to.to_s.sub(/\A(tag|branch|commit|ref) /, '')
      end

      # Hiera keys and lookups the proposed classes no longer answer, by the
      # class or class::param they name: driftless's validator run against a
      # schema of the current repo with the moving modules' classes replaced
      # by their proposed surfaces.
      def hiera_references(repo, _inventory, surfaces)
        return {} if surfaces.empty?

        code   = ::Driftless::Codebase.load(repo.dir)
        corpus = code.corpus(repo_dir: repo.dir)
        schema = ::Driftless::ParamsSchema.assemble(corpus: corpus)
        surfaces.each_value do |(from, to)|
          (from['classes'].keys + from['defined_types'].keys).each { |c| schema['classes'].delete(c) }
          to['classes'].merge(to['defined_types']).each do |name, entry|
            schema['classes'][name] = { 'file' => entry['file'], 'params' => entry['params'].transform_values { |p| { 'type' => p['type'], 'default' => p['default'] } } }
          end
        end
        issues = ::Driftless::ParamsSchema::Validate.new(schema).call(corpus)
        issues.each_with_object(Hash.new { |h, k| h[k] = [] }) do |issue, refs|
          key = (issue.kind == 'missing-class') ? issue.key.split('::')[0..-2].join('::') : issue.key
          refs[key] << "#{issue.path}:#{issue.line}"
        end
      rescue StandardError => e
        ::Pupgrade.logger.warn("impact: Hiera references not checked: #{e.message}")
        {}
      end

      def summary_row(change, history, findings)
        [change.name, change.from.to_s, change.to.to_s, history.commits ? history.commits.size.to_s : '?',
         findings.size.to_s, findings.count(&:used?).to_s]
      end

      def print_history(modules)
        modules.each do |change, history, _|
          next unless glob_any?(@options[:modules], change.name)

          puts ''
          commits = history.commits ? "#{history.commits.size} commit(s)" : 'commits unknown'
          puts "#{change.name}: #{change.from} -> #{change.to}, #{commits}"
          if @options[:gitlog] && history.commits
            history.commits.each { |c| puts "  #{c}" }
          end
          if @options[:changelog]
            puts(history.changelog ? history.changelog.lines.map { |l| "  #{l}" }.join : '  (no CHANGELOG sections for the versions crossed)')
          end
        end
      end

      def shown?(finding)
        (@options[:all] || finding.used? || finding.where == 'use unknown' || finding.where == 'use not tracked') &&
          glob_any?(@options[:modules], finding.module) &&
          (Array(@options[:kinds]).empty? || @options[:kinds].include?(finding.kind))
      end

      def glob_any?(globs, value)
        Array(globs).empty? || globs.any? { |g| File.fnmatch?(g, value, File::FNM_CASEFOLD) }
      end

      def check_kinds!
        unknown = Array(@options[:kinds]) - ::Pupgrade::Impact::Analysis::KINDS
        return if unknown.empty?

        fatal!("impact: unknown impact kind #{unknown.first.inspect} (known: #{::Pupgrade::Impact::Analysis::KINDS.join(', ')})", help: true)
      end

      def accumulate(key, values)
        (@options[key] ||= []).concat(values)
      end

      def log_warnings(warnings)
        warnings.each { |w| ::Pupgrade.logger.warn(w) }
      end

      def config_defaults
        cfg = ::Pupgrade.config
        {
          evidence:   cfg.dig('impact', 'evidence'),
          output_dir: cfg.dig('compile', 'output_dir') || 'pupgrade-catalogs',
        }.compact
      end
    end
  end
end
