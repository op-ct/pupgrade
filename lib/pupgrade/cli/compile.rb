require 'json'

require 'pupgrade/cli/base'
require 'pupgrade/cli/root'
require 'pupgrade/cli/table'
require 'pupgrade/config_keys'
require 'driftless/control_repo'
require 'pupgrade/compile/factset'
require 'pupgrade/compile/probe_record'
require 'pupgrade/compile/session'
require 'pupgrade/compile/mocks'

module Pupgrade
  module CLI
    # `pupgrade compile`
    #
    # One catalog per factset, compiled against the deployed environment
    # directory, written with a record of what the compile used:
    # OUT/<certname>/catalog.json and probes.json, plus error.txt when the
    # compile failed. Exit 1 when any did.
    class Compile < Base
      include Table
      extend ::Pupgrade::ConfigKeys::DSL

      register_command name: 'compile', subcommand_of: Root
      desc 'Compile catalogs from factsets and record what each compile used (`diff` compares two runs)'
      runs_without_subcommand

      config_key 'compile.factsets', type: :array, default: [], example: ['spec/factsets'],
                 about: 'Factset files or directories (onceover layout or a plain facts hash), relative to the control repo'
      config_key 'compile.catalogs_dir', type: :string, default: 'pupgrade/cache/catalogs',
                 about: 'Where `compile` writes <certname>/{catalog,probes}.json, relative to the control repo; what ' \
                        '`solve` and `impact` read as evidence of use'

      COLUMNS = %w[certname resources classes warnings mocks leaks status].freeze

      # The files read when the config names none and they exist.
      DEFAULT_MOCKS_FILE = 'pupgrade/compiler-mocks.yaml'.freeze
      DEFAULT_ENC_FILE   = 'pupgrade/enc.yaml'.freeze
      DEFAULT_RUBY_FILE  = 'pupgrade/compiler.rb'.freeze

      config_key 'compile.enc', type: :string, default: nil, example: DEFAULT_ENC_FILE,
                 about: 'Rules deciding each node\'s top-scope variables and classes from its certname and facts, ' \
                        "relative to the control repo; #{DEFAULT_ENC_FILE} when it exists"
      config_key 'compile.ruby', type: :string, default: nil, example: DEFAULT_RUBY_FILE,
                 about: 'Ruby blocks deciding variables, classes, and mock answers per node, loaded after the rules, ' \
                        "relative to the control repo; #{DEFAULT_RUBY_FILE} when it exists"

      def execute(argv)
        reject_extra_args!(argv)
        if @options[:show_default_mocks]
          print File.read(::Pupgrade::Compile::Mocks::DEFAULTS_FILE)
          exit 0
        end
        repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
        fatal!('compile requires --repo-dir (auto-detection did not supply it)', help: true) unless repo
        fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?
        fatal!('compile needs at least one --factsets PATH (config: compile.factsets)', help: true) if Array(@options[:factsets]).empty?

        factsets = load_factsets(repo)
        ::Pupgrade.logger.notice("compile: #{factsets.size} factset(s) against #{repo.dir}")
        session  = build_session(repo)
        out      = File.expand_path(@options[:catalogs_dir], repo.dir)
        rows     = []
        failures = []
        progress = @options[:progress].nil? ? $stdout.tty? : @options[:progress]
        begin
          factsets.each do |factset|
            result = session.compile(factset)
            write(out, result)
            rows << row(result)
            $stdout.print(result.ok? ? paint('P', :green) : paint('F', :red)) if progress
            if result.ok?
              ::Pupgrade.logger.info("compile: #{result.certname} in #{'%.1f' % result.seconds}s")
            else
              failures << result
              ::Pupgrade.logger.warning("compile: #{result.certname} failed in #{'%.1f' % result.seconds}s: #{result.error}")
            end
            ::Pupgrade.logger.debug("compile: #{result.certname}: #{probe_counts(result.probes)}")
            break if @options[:fail_fast] && !result.ok?
          end
        ensure
          session.close
        end
        puts '' if progress
        print_table(COLUMNS, rows)
        failures.each { |r| puts "#{paint(r.certname, :red)}: #{r.error}" }
        failed = failures.size
        if @options[:fail_fast] && failed.positive? && rows.size < factsets.size
          ::Pupgrade.logger.notice("compile: stopped at the first failure; #{factsets.size - rows.size} factset(s) not compiled")
        end
        stale = (Array(@options[:certnames]).empty? && !@options[:keep_stale]) ? remove_stale(out, factsets) : []
        ::Pupgrade.logger.notice("compile: #{rows.size - failed} compiled, #{failed} failed; written to #{out}" \
                               "#{"; removed #{stale.size} node(s) no factset names: #{stale.join(', ')}" unless stale.empty?}")
        exit(failed.zero? ? 0 : 1)
      end

      protected

      def configure_parser(o)
        o.on('-d', '--repo-dir=DIR', 'Path to the deployed control repo environment',
             "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
        o.on('--factsets=PATH', Array, 'Factset files or directories, comma-separated, repeatable',
             '(config: compile.factsets)') { |v| accumulate(:factsets, v) }
        o.on('-o', '--catalogs-dir=DIR', 'Where to write <certname>/ directories (config: compile.catalogs_dir)') { |v| @options[:catalogs_dir] = v }
        o.on('--certname=GLOBS', Array, 'Only factsets whose certname matches (case-insensitive)') { |v| accumulate(:certnames, v) }
        o.on('-f', '--[no-]fail-fast', 'Stop at the first compile that fails') { |v| @options[:fail_fast] = v }
        o.on('--[no-]progress', 'Print a green P or red F per compile as it goes (default: when stdout is a terminal)') { |v| @options[:progress] = v }
        o.on('--keep-stale', 'Keep <certname>/ directories of nodes the factsets no longer name') { @options[:keep_stale] = true }

        o.separator ''
        o.separator 'What to compile:'
        o.on('--environment=NAME', 'Environment name (config: compile.environment)') { |v| @options[:environment] = v }
        o.on('--manifest=PATH', 'A manifest file or directory in place of environment.conf\'s (config: compile.manifest)') { |v| @options[:manifest] = v }
        o.on('--code=CODE', 'Puppet code compiled in place of the manifest') { |v| @options[:code] = v }
        o.on('--prepend=CODE', 'Puppet code evaluated before the manifest; @FILE reads it from a file',
             '(config: compile.prepend_file names the file)') { |v| @options[:prepend] = v }
        o.on('--var=NAME=VALUE', 'A top-scope variable for every node, repeatable (config: compile.vars)') { |v| pair(:vars, v) }
        o.on('--enc=FILE', "Rules deciding variables and classes per node (config: compile.enc; default: #{DEFAULT_ENC_FILE}",
             'when it exists)') { |v| @options[:enc] = v }
        o.on('--ruby=FILE', "Ruby blocks deciding variables, classes, and mock answers (config: compile.ruby; default: #{DEFAULT_RUBY_FILE}",
             'when it exists)') { |v| @options[:ruby] = v }
        o.on('--server-fact=NAME=VALUE', 'An entry of $server_facts, repeatable (config: compile.server_facts)') { |v| pair(:server_facts, v) }

        o.separator ''
        o.separator 'The execution guard:'
        o.on('--mocks=FILE', "YAML answering commands and facts module code asks for (config: compile.mocks; default: #{DEFAULT_MOCKS_FILE}",
             'when it exists)') { |v| @options[:mocks] = v }
        o.on('--show-default-mocks', 'Print the mocks pupgrade applies after the file, and exit') { @options[:show_default_mocks] = true }
        o.on('--on-mock=LEVEL', ::Pupgrade::Compile::Recorder::ON_MOCK,
             "Log each mocked answer at LEVEL (#{::Pupgrade::Compile::Recorder::ON_MOCK.join(', ')}; default: debug)") { |v| @options[:on_mock] = v }
        o.on('--[no-]default-mocks', 'Apply pupgrade\'s own mocks for package-provider probes after the file (config: compile.default_mocks)') { |v| @options[:default_mocks] = v }
        o.on('--on-leak=POLICY', ::Pupgrade::Compile::Session::ON_LEAK,
             'For a command the mocks do not answer: raise (default) or allow (config: compile.on_leak)') { |v| @options[:on_leak] = v }

        o.separator ''
        o.separator 'Writes <certname>/catalog.json (Puppet\'s catalog data, sorted) and probes.json (functions,'
        o.separator 'facts, lookups, providers, warnings, deprecations, leaks) under the catalogs directory.'
        o.separator 'The table counts the commands and facts the mocks answered (mocks) apart from those'
        o.separator 'nothing answered (leaks: raised, allowed to run, or a fact missing). A command nothing'
        o.separator 'answers is logged at warning. Exits 1 when a compile fails; its error is listed under'
        o.separator 'the table and kept in <certname>/error.txt.'
      end

      private

      def load_factsets(repo)
        paths = Array(@options[:factsets]).map { |p| File.expand_path(p, repo.dir) }
        all   = ::Pupgrade::Compile::Factset.load_all(paths)
        globs = Array(@options[:certnames])
        all = all.select { |f| globs.any? { |g| File.fnmatch?(g, f.certname, File::FNM_CASEFOLD) } } unless globs.empty?
        fatal!('compile: no factsets matched', 3) if all.empty?
        all
      rescue ::Pupgrade::Compile::Factset::Error => e
        fatal!("compile: #{e.message}", 3)
      end

      def build_session(repo)
        defaults = @options.fetch(:default_mocks, true)
        path  = file_option(repo, :mocks, DEFAULT_MOCKS_FILE)
        mocks = path ? ::Pupgrade::Compile::Mocks.load(path, defaults: defaults) : ::Pupgrade::Compile::Mocks.empty(defaults: defaults)
        ::Pupgrade.logger.info("compile: mocks from #{path || 'nowhere'}#{' plus the defaults' if defaults}")
        enc = ::Pupgrade::Compile::Enc.load(file_option(repo, :enc, DEFAULT_ENC_FILE), file_option(repo, :ruby, DEFAULT_RUBY_FILE),
                                            vars: @options[:vars] || {})
        mocks.blocks = enc.ruby.mocks
        prepend = @options[:prepend]
        prepend = "@#{@options[:prepend_file]}" if prepend.nil? && @options[:prepend_file]
        prepend = File.read(File.expand_path(prepend.delete_prefix('@'), repo.dir)) if prepend&.start_with?('@')
        ::Pupgrade::Compile::Session.new(
          repo_dir: repo.dir, environment: @options[:environment], manifest: @options[:manifest], code: @options[:code],
          prepend: prepend, enc: enc, server_facts: @options[:server_facts] || {},
          mocks: mocks, on_leak: @options[:on_leak], on_mock: @options[:on_mock] || 'debug',
        ).start
      rescue ::Pupgrade::Compile::Session::Error, ::Pupgrade::Compile::Mocks::Error, ::Pupgrade::Compile::Enc::Error, Errno::ENOENT => e
        fatal!("compile: #{e.message}", 3)
      end

      # The file an option names, relative to the repo, else the default
      # when it is there.
      #
      # @return [String, nil] absolute
      def file_option(repo, key, default)
        return File.expand_path(@options[key], repo.dir) if @options[key]

        path = File.join(repo.dir, default)
        File.file?(path) ? path : nil
      end

      def write(out, result)
        dir = File.join(out, result.certname)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, 'probes.json'), JSON.pretty_generate(probes_document(result)) + "\n")
        if result.catalog
          File.write(File.join(dir, 'catalog.json'), JSON.pretty_generate(result.catalog) + "\n")
        else
          FileUtils.rm_f(File.join(dir, 'catalog.json'))
        end
        error = File.join(dir, 'error.txt')
        result.ok? ? FileUtils.rm_f(error) : File.write(error, result.error + "\n")
      end

      # A full run owns its output directory: a node directory from an
      # earlier run whose factset is gone is removed, so the evidence never
      # outlives the factsets.
      #
      # @return [Array<String>] the certnames removed
      def remove_stale(out, factsets)
        return [] unless File.directory?(out)

        current = factsets.map(&:certname)
        Dir.children(out).select { |n| File.directory?(File.join(out, n)) && File.file?(File.join(out, n, 'probes.json')) && !current.include?(n) }.sort.each do |name|
          FileUtils.rm_rf(File.join(out, name))
        end
      end

      def probe_counts(probes)
        %w[classes defined_types functions facts lookups warnings leaks].filter_map { |k| "#{probes[k].size} #{k.tr('_', ' ')}" if probes[k].respond_to?(:size) }.join(', ')
      end

      def probes_document(result)
        {
          'document'       => ::Pupgrade::Compile::ProbeRecord::DOCUMENT,
          'schema_version' => ::Pupgrade::Compile::ProbeRecord::SCHEMA_VERSION,
          'certname'       => result.certname,
          'factset'        => result.factset.path,
          'environment'    => @options[:environment],
          'status'         => result.ok? ? 'ok' : 'failed',
          'error'          => result.error,
          'seconds'        => result.seconds.round(3),
        }.compact.merge(result.probes)
      end

      # The mocks column counts what the mocks answered; leaks what nothing
      # did, red when one stopped the compile, yellow when it ran or a fact
      # was missing.
      def row(result)
        p = result.probes
        actions = p['leaks'].map { |l| l['action'].to_s }
        mocked  = actions.count { |a| a.start_with?('mocked') }
        raised  = actions.count('raised')
        leaked  = actions.size - mocked
        leaks   = if raised.positive? then paint(leaked.to_s, :red)
                  elsif leaked.positive? then paint(leaked.to_s, :yellow)
                  else leaked.to_s
                  end
        [result.certname,
         result.catalog ? result.catalog['resources'].size.to_s : '-',
         result.catalog ? result.catalog['classes'].size.to_s : '-',
         (p['warnings'].size + p['deprecations'].size).to_s,
         mocked.to_s, leaks,
         result.ok? ? paint('ok', :green) : paint('failed', :red)]
      end

      def accumulate(key, values)
        (@options[key] ||= []).concat(values)
      end

      def pair(key, text)
        name, value = text.split('=', 2)
        fatal!("compile: expected NAME=VALUE, got #{text.inspect}", help: true) if name.nil? || name.empty? || value.nil?
        (@options[key] = (@options[key] || {}).dup)[name] = value
      end

      def config_defaults
        cfg = ::Pupgrade.config
        {
          factsets:     cfg.dig('compile', 'factsets'),
          catalogs_dir: cfg.dig('compile', 'catalogs_dir') || 'pupgrade/cache/catalogs',
          environment:  cfg.dig('compile', 'environment') || 'production',
          manifest:     cfg.dig('compile', 'manifest'),
          prepend_file: cfg.dig('compile', 'prepend_file'),
          mocks:        cfg.dig('compile', 'mocks'),
          enc:          cfg.dig('compile', 'enc'),
          ruby:         cfg.dig('compile', 'ruby'),
          default_mocks: cfg.dig('compile', 'default_mocks'),
          on_leak:      cfg.dig('compile', 'on_leak') || 'raise',
          vars:         cfg.dig('compile', 'vars'),
          server_facts: cfg.dig('compile', 'server_facts'),
        }.compact
      end
    end
  end
end

Dir[File.join(__dir__, 'compile', '*.rb')].sort.each { |f| require f }
