require 'driftless/control_repo'
require 'pupgrade/compile/enc'
require 'pupgrade/compile/factset'
require 'pupgrade/compile/mocks'
require 'pupgrade/compile/session'

module Pupgrade
  module CLI
    # What `compile` and `lookup` share: the options naming the factsets,
    # the code to compile, the ENC stand-in, and the execution guard, and
    # the session they build from them.
    module CompileOptions
      # The files read when the config names none and they exist.
      DEFAULT_MOCKS_FILE = 'pupgrade/compiler-mocks.yaml'.freeze
      DEFAULT_ENC_FILE   = 'pupgrade/enc.yaml'.freeze
      DEFAULT_RUBY_FILE  = 'pupgrade/compiler.rb'.freeze

      def declare_repo_and_factsets(o)
        o.on('-d', '--repo-dir=DIR', 'Path to the deployed control repo environment',
             "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
        o.on('--factsets=PATH', Array, 'Factset files or directories, comma-separated, repeatable',
             '(config: compile.factsets)') { |v| accumulate(:factsets, v) }
      end

      def declare_what_to_compile(o)
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
      end

      def declare_guard(o)
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
      end

      # @return [Driftless::ControlRepo]
      def control_repo!(command)
        repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
        fatal!("#{command} requires --repo-dir (auto-detection did not supply it)", help: true) unless repo
        fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?
        repo
      end

      # The factsets named, narrowed by `--certname` globs.
      #
      # @return [Array<Compile::Factset>]
      def load_factsets(repo, command)
        fatal!("#{command} needs at least one --factsets PATH (config: compile.factsets)", help: true) if Array(@options[:factsets]).empty?
        paths = Array(@options[:factsets]).map { |p| File.expand_path(p, repo.dir) }
        all   = ::Pupgrade::Compile::Factset.load_all(paths)
        globs = Array(@options[:certnames])
        all = all.select { |f| globs.any? { |g| File.fnmatch?(g, f.certname, File::FNM_CASEFOLD) } } unless globs.empty?
        fatal!("#{command}: no factsets matched", 3) if all.empty?
        all
      rescue ::Pupgrade::Compile::Factset::Error => e
        fatal!("#{command}: #{e.message}", 3)
      end

      # The ENC stand-in from the files named or found.
      #
      # @return [Compile::Enc]
      def build_enc(repo)
        ::Pupgrade::Compile::Enc.load(file_option(repo, :enc, DEFAULT_ENC_FILE), file_option(repo, :ruby, DEFAULT_RUBY_FILE),
                                      vars: @options[:vars] || {})
      end

      # A started session: mocks, ENC stand-in, and what to compile, from
      # the options.
      #
      # @return [Compile::Session]
      def build_session(repo, command)
        defaults = @options.fetch(:default_mocks, true)
        path  = file_option(repo, :mocks, DEFAULT_MOCKS_FILE)
        mocks = path ? ::Pupgrade::Compile::Mocks.load(path, defaults: defaults) : ::Pupgrade::Compile::Mocks.empty(defaults: defaults)
        ::Pupgrade.logger.info("#{command}: mocks from #{path || 'nowhere'}#{' plus the defaults' if defaults}")
        enc = build_enc(repo)
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
        fatal!("#{command}: #{e.message}", 3)
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

      def accumulate(key, values)
        (@options[key] ||= []).concat(values)
      end

      def pair(key, text)
        name, value = text.split('=', 2)
        fatal!("expected NAME=VALUE, got #{text.inspect}", help: true) if name.nil? || name.empty? || value.nil?
        (@options[key] = (@options[key] || {}).dup)[name] = value
      end

      # The `compile.*` keys as option defaults.
      def compile_config_defaults
        cfg = ::Pupgrade.config
        {
          factsets:      cfg.dig('compile', 'factsets'),
          catalogs_dir:  cfg.dig('compile', 'catalogs_dir') || 'pupgrade/cache/catalogs',
          environment:   cfg.dig('compile', 'environment') || 'production',
          manifest:      cfg.dig('compile', 'manifest'),
          prepend_file:  cfg.dig('compile', 'prepend_file'),
          mocks:         cfg.dig('compile', 'mocks'),
          enc:           cfg.dig('compile', 'enc'),
          ruby:          cfg.dig('compile', 'ruby'),
          default_mocks: cfg.dig('compile', 'default_mocks'),
          on_leak:       cfg.dig('compile', 'on_leak') || 'raise',
          vars:          cfg.dig('compile', 'vars'),
          server_facts:  cfg.dig('compile', 'server_facts'),
        }.compact
      end
    end
  end
end
