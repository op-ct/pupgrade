require 'pupgrade/cli/base'
require 'pupgrade/cli/module_command'
require 'pupgrade/cli/table'
require 'driftless/git_clone'
require 'driftless/module_inventory'
require 'pupgrade/solve/candidates'

module Pupgrade
  module CLI
    class ModuleCommand
      # `pupgrade module release`
      #
      # One module's releases: every tag naming a version on the branch it
      # follows, past and future, oldest first, with the date of each and
      # the deployed one marked.
      class Release < Base
        include Table
        include ModuleCommand::Shared

        register_command name: 'release', subcommand_of: ModuleCommand
        positional '<module>'
        desc 'List one module\'s releases, past and future: version, tag, and date, the deployed one marked'

        COLUMNS = ['version', 'tag', 'released', ''].freeze

        def execute(argv)
          fatal!('module release takes a module', help: true) unless argv.size == 1
          repo      = control_repo!('module release')
          inventory = ::Driftless::ModuleInventory.new(repo.dir)
          entry     = inventory.find(argv.first)
          fatal!("module release: no module #{argv.first.inspect} on the modulepath or in the Puppetfile", 3) unless entry

          branch     = @options[:branch] && given_branch('module release', repo, entry)
          candidates = ::Pupgrade::Solve::Candidates.new(repo.dir, branchfile: @options[:branchfile], include_heads: @options[:include_heads],
                                                         fetch: @options[:fetch])
          list = candidates.releases(entry, branch: branch)
          candidates.warnings.each { |w| ::Pupgrade.logger.warn(w) }
          fatal!("module release: #{entry.path}: #{list.reason}", 3) if list.is_a?(::Pupgrade::Solve::Candidates::Unsolvable)

          clone = ::Driftless::GitClone.new(File.join(repo.dir, entry.path))
          print_table(COLUMNS, list.map { |c| row(clone, c) })
          name = entry.metadata.name || entry.declared&.name || File.basename(entry.path)
          branch ||= (entry.declared.ref_type == 'branch') ? entry.declared.ref.to_s : branch_for(repo, entry)
          ::Pupgrade.logger.notice("module release: #{name}: #{list.size} release(s)#{" on #{branch}" if branch}")
          exit 0
        end

        protected

        def configure_parser(o)
          declare_repo_option(o)
          o.on('--branch=BRANCHES', Array, 'Follow the first of these branches the clone has; with a branchfile, record it there') { |v| @options[:branch] = v }
          o.on('--branchfile=FILE', 'The branchfile naming the branch the module follows (config: modules.branchfile)') { |v| @options[:branchfile] = v }
          o.on('--fetch', 'Fetch the clone\'s origin first') { @options[:fetch] = true }
          o.on('--include-heads', 'The tip of the branch as a last row') { @options[:include_heads] = true }
        end

        private

        # A tag cyan and a branch tip magenta, the colors `module list` gives
        # a declaration; the deployed row marked green.
        def row(clone, candidate)
          ref  = paint(candidate.ref, (candidate.ref_type == 'tag') ? :cyan : :magenta)
          date = clone.log('-1', '--format=%cs', "#{candidate.ref}^{commit}") || ''
          [candidate.version.to_s, ref, date, candidate.current ? paint('(deployed)', :green) : '']
        end

        def config_defaults
          { branchfile: ::Pupgrade.config.dig('modules', 'branchfile') }.compact
        end
      end
    end
  end
end
