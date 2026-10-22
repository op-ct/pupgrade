require 'pupgrade/cli/base'
require 'pupgrade/cli/root'

module Pupgrade
  module CLI
    # `pupgrade module`: the parent of the commands that act on one
    # deployed module. Named apart from ::Module, which the command's name
    # would shadow inside this namespace.
    class ModuleCommand < Base
      register_command name: 'module', subcommand_of: Root
      desc 'Act on one deployed module: its git log, or moving it to a ref (see subcommands)'

      # What the commands acting on one module share: finding the repo and
      # the module named on the command line.
      module Shared
        def declare_repo_option(o)
          o.on('-d', '--repo-dir=DIR',
               'Path to the control repo environment',
               "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
        end

        # @return [Driftless::ControlRepo]
        def control_repo!(command)
          repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
          fatal!("#{command} requires --repo-dir (auto-detection did not supply it)", help: true) unless repo
          fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?
          repo
        end

        # The module's entry and its clone, stopping unless it is a git
        # clone on disk.
        #
        # @return [Array(Driftless::ModuleInventory::Entry, Driftless::GitClone)]
        def git_module!(command, repo, selector)
          require 'driftless/git_clone'
          require 'driftless/module_inventory'

          inventory = ::Driftless::ModuleInventory.new(repo.dir)
          entry     = inventory.find(selector)
          inventory.warnings.each { |w| ::Pupgrade.logger.warn(w) }
          fatal!("#{command}: no module #{selector.inspect} on the modulepath or in the Puppetfile", 3) unless entry
          fatal!("#{command}: #{entry.path} is not deployed", 3) if entry.deployed == :absent

          clone = ::Driftless::GitClone.new(File.join(repo.dir, entry.path))
          fatal!("#{command}: #{entry.path} is not a git clone", 3) unless clone.own?
          [entry, clone]
        end

        # Git's own rev syntax: a suffix, a reflog or range operator.
        REV_EXPRESSION = /[\^~:]|@\{|\.\./.freeze

        # The ref as git should see it: a rev expression (`HEAD~2`,
        # `main@{2.weeks.ago}`) as given, since prefixing it would change its
        # meaning; a plain name as `origin/<name>` when the clone has that,
        # since a deployed clone's own branches are stale, else as given.
        #
        # @return [String, nil] nil when the clone resolves neither
        def ref_candidate(clone, ref)
          names = ref.match?(REV_EXPRESSION) ? [ref] : ["origin/#{ref}", ref]
          names.find { |r| clone.resolve(r) }
        end
      end
    end
  end
end

Dir[File.join(__dir__, 'module', '*.rb')].sort.each { |f| require f }
