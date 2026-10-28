require 'open3'

require 'pupgrade/cli/base'
require 'pupgrade/cli/module_command'
require 'driftless/control_repo'
require 'driftless/git_clone'
require 'driftless/module_inventory'
require 'pupgrade/inputs/branchfile'
require 'pupgrade/solve/candidates'

module Pupgrade
  module CLI
    class ModuleCommand
      # `pupgrade module info`
      #
      # One module in full: its names, where it is, what the Puppetfile
      # declares, what the clone sits at, what its metadata claims (at a ref
      # of the clone, when one is named), the branch it follows, and the
      # versions it could move to.
      class Info < Base
        include ModuleCommand::Shared

        register_command name: 'info', subcommand_of: ModuleCommand
        positional '<module>[:<ref>]'
        desc 'Show one module: names, declaration, deployment, metadata, branch, and candidates'

        def execute(argv)
          fatal!('module info takes a module', help: true) unless argv.size == 1
          repo = control_repo!('module info')
          require 'driftless/module_inventory'
          inventory = ::Driftless::ModuleInventory.new(repo.dir)
          name, sep, ref = argv.first.rpartition(':')
          if sep.empty? || ref.empty?
            name = argv.first
            ref  = nil
          end
          entry = inventory.find(name)
          fatal!("module info: no module #{name.inspect} on the modulepath or in the Puppetfile", 3) unless entry

          lines(repo, entry, ref && at_ref(repo, entry, ref)).each { |label, value| puts "#{label}:".ljust(15) + value.to_s }
          exit 0
        end

        protected

        def configure_parser(o)
          declare_repo_option(o)
          o.on('--branchfile=FILE', 'The branchfile naming the branch the module follows (config: modules.branchfile)') { |v| @options[:branchfile] = v }
          o.on('--fetch', 'Fetch the clone\'s origin before listing candidates') { @options[:fetch] = true }
        end

        private

        # @param at [Array(String, String, Driftless::Inputs::ModuleMetadata::Result), nil]
        #   the ref, its sha, and the metadata there, from {#at_ref}
        def lines(repo, entry, at)
          declared = entry.declared
          metadata = at ? at.last : entry.metadata
          out = []
          out << ['name', [metadata.name, declared&.name].compact.uniq.join(', ')]
          out << ['path', entry.path]
          out << ['declared', declared ? declaration(declared) : 'not in the Puppetfile']
          out << ['remote', declared.git] if declared&.git
          out.concat(clone_lines(repo, entry))
          out << ['deployed', entry.found ? "#{entry.deployed} (#{entry.found})" : entry.deployed.to_s]
          out << ['read at', "#{at[0]} (#{at[1][0, 12]})"] if at
          out << ['version', metadata.version.to_s]
          out << ['dependencies', metadata.dependencies.map { |n, r| [n, r].compact.join(' ') }.join('; ')] unless metadata.dependencies.empty?
          out << ['requirements', metadata.requirements.map { |n, r| "#{n} #{r}" }.join('; ')] unless metadata.requirements.empty?
          unless metadata.operatingsystem_support.empty?
            out << ['OS support', metadata.operatingsystem_support.map { |os, rel| "#{os} #{Array(rel).join('/')}".strip }.join(', ')]
          end
          out.concat(candidate_lines(repo, entry))
          out
        end

        # The module's metadata at a ref of its clone, the ref as `gitlog`
        # takes it.
        #
        # @return [Array(String, String, Driftless::Inputs::ModuleMetadata::Result)]
        #   the ref, its sha, and the metadata
        def at_ref(repo, entry, ref)
          clone = ::Driftless::GitClone.new(File.join(repo.dir, entry.path))
          fatal!("module info: #{entry.path} is not a git clone, so has no ref #{ref.inspect}", 3) unless clone.own?
          name = ref_candidate(clone, ref)
          fatal!("module info: #{entry.path} has no ref #{ref.inspect}", 3) unless name

          sha = clone.resolve(name)
          text, status = Open3.capture2('git', '-C', clone.dir, 'show', "#{sha}:#{::Driftless::Inputs::ModuleMetadata::FILENAME}", err: File::NULL)
          fatal!("module info: #{entry.path} has no metadata.json at #{ref}", 3) unless status.success?

          metadata = ::Driftless::Inputs::ModuleMetadata.parse(text, path: "#{entry.path}@#{ref}:metadata.json")
          fatal!("module info: #{metadata.error}", 3) if metadata.error
          [ref, sha, metadata]
        end

        def declaration(declared)
          return "#{declared.version || '(no version)'} (forge)" unless declared.git

          "#{declared.ref_type || 'ref'} #{declared.ref || 'HEAD'}"
        end

        def clone_lines(repo, entry)
          dir = File.join(repo.dir, entry.path)
          return [] unless File.directory?(dir)

          clone = ::Driftless::GitClone.new(dir)
          return [] unless clone.own?

          at = [clone.tag_at_head && "tag #{clone.tag_at_head}", clone.branch_at_head && "branch #{clone.branch_at_head}", clone.sha&.slice(0, 12)].compact
          [['clone', at.join(', ')]]
        end

        def candidate_lines(repo, entry)
          candidates = ::Pupgrade::Solve::Candidates.new(repo.dir, branchfile: @options[:branchfile], include_heads: true, fetch: @options[:fetch])
          list = candidates.for(entry)
          candidates.warnings.each { |w| ::Pupgrade.logger.warn(w) }
          branch = branch_for(repo, entry)
          out = []
          out << ['branch', branch] if branch
          if list.is_a?(::Pupgrade::Solve::Candidates::Unsolvable)
            out << ['candidates', "none (#{list.reason})"]
          else
            newer = list.reject(&:current)
            out << ['candidates', newer.empty? ? 'none past the current version' : newer.map(&:ref).join(', ')]
          end
          out
        end

        def branch_for(repo, entry)
          return nil unless @options[:branchfile]

          result = ::Pupgrade::Inputs::Branchfile.load(File.expand_path(@options[:branchfile], repo.dir))
          return nil if result.error || !result.exists?

          [entry.declared&.name, entry.metadata.name, File.basename(entry.path)].compact.filter_map { |n| result.branch_for(n) }.first
        end

        def config_defaults
          { branchfile: ::Pupgrade.config.dig('modules', 'branchfile') }.compact
        end
      end
    end
  end
end
