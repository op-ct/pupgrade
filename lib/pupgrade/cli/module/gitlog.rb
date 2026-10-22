require 'pupgrade/cli/base'
require 'pupgrade/cli/module_command'
require 'driftless/control_repo'
require 'pupgrade/inputs/branchfile'

module Pupgrade
  module CLI
    class ModuleCommand
      # `pupgrade module gitlog`
      #
      # The git log of one deployed module: with a ref or --branch, the
      # commits it has beyond the clone's HEAD; without either, the branch
      # a branchfile names for the module, else the clone's history.
      class Gitlog < Base
        include ModuleCommand::Shared

        register_command name: 'gitlog', subcommand_of: ModuleCommand
        positional '<module>', '[<ref>]'
        desc 'Show a deployed module\'s git log, or what a ref has beyond it'

        def execute(argv)
          fatal!('module gitlog takes a module and an optional ref', help: true) unless argv.size.between?(1, 2)
          selector, ref = argv
          fatal!('module gitlog: give a ref or --branch, not both', help: true) if ref && @options[:branch]
          repo = control_repo!('module gitlog')
          entry, clone = git_module!('module gitlog', repo, selector)
          branch = @options[:branch] && pick_branch(clone, @options[:branch])
          ref ||= branch || branch_from_file(repo, entry)
          record_branch(repo, entry, branch) if branch && @options[:branchfile]

          if @options[:fetch]
            fatal!("module gitlog: fetch from #{clone.remote || 'origin'} failed", 3) unless clone.fetch
          end

          args = ['--abbrev-commit', "--format=format:#{line_format}",
                  "--color=#{::Pupgrade::Ansi.enabled?($stdout) ? 'always' : 'never'}"]
          args << '--date=format:%Y-%m-%d %H:%M:%S' if @options[:date]
          args.push('-n', @options[:count].to_s) if @options[:count]
          args << '--name-status' if @options[:name_status]
          args << '--simplify-by-decoration' if @options[:tags_only]
          args << range_for(clone, ref)
          out = clone.log(*args)
          fatal!("module gitlog: git log failed in #{entry.path}", 3) if out.nil?

          out = tagged_lines(out, ref) if @options[:tags_only]
          puts out unless out.empty?
          ::Pupgrade.logger.notice("module gitlog: #{entry.path} at #{clone.tag_at_head || clone.branch_at_head || clone.sha&.slice(0, 12)}")
          exit 0
        end

        protected

        def option_defaults
          { date: true }
        end

        def configure_parser(o)
          declare_repo_option(o)
          o.on('-n', '--count=NUM', Integer, 'Show at most NUM commits') { |v| @options[:count] = v }
          o.on('-f', '--name-status', 'List the files each commit changed') { @options[:name_status] = true }
          o.on('--[no-]date', 'Show each commit\'s date after its hash (default: on)') { |v| @options[:date] = v }
          o.on('--fetch', 'Fetch origin first, so a branch or tag the clone has not seen shows') { @options[:fetch] = true }
          o.on('--branch=BRANCHES', Array, 'Follow the first of these branches the clone has, as <ref> would;',
               'with a branchfile (flag or config), record it there') { |v| @options[:branch] = v }
          o.on('-t', '--tags-only', 'Show only tagged commits (and the branch tip with --include-heads)') { @options[:tags_only] = true }
          o.on('--include-heads', 'With --tags-only, keep the tip of the ref as well') { @options[:include_heads] = true }
          o.on('--from-start', 'Log <ref> from its first commit, not only what it has beyond HEAD') { @options[:from_start] = true }
          o.on('--branchfile=FILE',
               'Without <ref> or --branch, follow the branch FILE names for the module:',
               'YAML of module to branch, or a Puppetfile overlay of mod entries with',
               ':branch (default: modules.branchfile in pupgrade.yaml)') do |v|
            @options[:branchfile]       = v
            @options[:branchfile_given] = true
          end
          o.separator ''
          o.separator '<ref> is a branch, tag, or sha, tried as origin/<ref> first (a deployed clone\'s own'
          o.separator 'branches are stale) and then as given; a rev expression such as HEAD~3 or'
          o.separator 'main@{2.weeks.ago} goes to git as written. The log then covers HEAD..<ref>, what'
          o.separator 'the ref has that the clone does not, or all of <ref> with --from-start. Without'
          o.separator 'a ref, the log is the clone\'s history.'
          o.separator 'Lines are coloured when --[no-]color, output.color, or a terminal says so.'
        end

        private

        # One line per commit: hash, the date unless --no-date, decoration,
        # and subject. git drops the colour codes under --color=never.
        def line_format
          date = @options[:date] ? '  %C(bold green)%cd%C(reset)' : ''
          "%C(bold blue)%h%C(reset)#{date}%C(bold yellow)%d%C(reset) %s"
        end

        # The branch the branchfile names for the module, when there is a
        # branchfile and it names one.
        #
        # @return [String, nil]
        def branch_from_file(repo, entry)
          return nil unless @options[:branchfile]

          path   = File.expand_path(@options[:branchfile], repo.dir)
          result = ::Pupgrade::Inputs::Branchfile.load(path)
          fatal!("module gitlog: branchfile #{path}: no such file", 3) unless result.exists?
          fatal!("module gitlog: branchfile #{result.error}", 3) if result.error
          result.warnings.each { |w| ::Pupgrade.logger.warn(w) }

          branch = [entry.declared&.name, entry.metadata.name, File.basename(entry.path)].compact.filter_map { |n| result.branch_for(n) }.first
          ::Pupgrade.logger.debug("module gitlog: #{entry.path} follows #{branch} per #{path}") if branch
          branch
        end

        # The first of the branches the clone knows, as origin/<branch> or
        # as given.
        def pick_branch(clone, branches)
          found = branches.find { |b| clone.resolve("origin/#{b}") || clone.resolve(b) }
          fatal!("module gitlog: none of #{branches.join(', ')} is a branch the clone knows (try --fetch)", 3) unless found
          found
        end

        # Only the lines of tagged commits, and the tip's line with
        # --include-heads.
        def tagged_lines(out, ref)
          lines = out.lines
          kept  = lines.select { |l| l.match?(/\(.*tag: /) }
          kept.unshift(lines.first) if @options[:include_heads] && ref && lines.first && !kept.include?(lines.first)
          kept.join
        end

        # Writes the branch for the module into the branchfile, the one on
        # the command line or the configured one, under the Puppetfile's
        # name for it.
        def record_branch(repo, entry, branch)
          path = File.expand_path(@options[:branchfile], repo.dir)
          name = entry.declared&.name || entry.metadata.name || File.basename(entry.path)
          ::Pupgrade::Inputs::Branchfile.record(path, name, branch)
          ::Pupgrade.logger.notice("module gitlog: recorded #{name}: #{branch} in #{path}")
        rescue ::Pupgrade::Inputs::Branchfile::Error => e
          fatal!("module gitlog: branchfile #{e.message}", 3)
        end

        def config_defaults
          { branchfile: ::Pupgrade.config.dig('modules', 'branchfile') }.compact
        end

        # @return [String] the `git log` revision argument
        def range_for(clone, ref)
          return 'HEAD' if ref.nil?

          candidate = ref_candidate(clone, ref)
          fatal!("module gitlog: #{ref.inspect} is not a ref the clone resolves (try --fetch)", 3) unless candidate
          @options[:from_start] ? candidate : "HEAD..#{candidate}"
        end
      end
    end
  end
end
