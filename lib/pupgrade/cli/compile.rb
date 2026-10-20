require 'json'

require 'pupgrade/cli/base'
require 'pupgrade/cli/root'
require 'pupgrade/cli/table'
require 'pupgrade/config_keys'
require 'driftless/control_repo'
require 'pupgrade/compile/factset'
require 'pupgrade/compile/session'
require 'pupgrade/compile/stubs'

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
      config_key 'compile.output_dir', type: :string, default: 'pupgrade-catalogs',
                 about: 'Where `compile` writes OUT/<certname>/{catalog,probes}.json, relative to the control repo'

      COLUMNS = %w[certname resources classes warnings leaks status].freeze

      def execute(argv)
        reject_extra_args!(argv)
        repo = @options[:repo_dir] ? ::Driftless::ControlRepo.new(@options[:repo_dir]) : ::Driftless::ControlRepo.detect(Dir.pwd)
        fatal!('compile requires --repo-dir (auto-detection did not supply it)', help: true) unless repo
        fatal!("repo-dir not readable: #{repo.dir}", 3) unless repo.readable?
        fatal!('compile needs at least one --factsets PATH (config: compile.factsets)', help: true) if Array(@options[:factsets]).empty?

        factsets = load_factsets(repo)
        session  = build_session(repo)
        out      = File.expand_path(@options[:output_dir], repo.dir)
        rows     = []
        failed   = 0
        begin
          factsets.each do |factset|
            result = session.compile(factset)
            write(out, result)
            failed += 1 unless result.ok?
            rows << row(result)
            ::Pupgrade.logger.debug("compile: #{result.certname} in #{'%.1f' % result.seconds}s#{": #{result.error}" unless result.ok?}")
          end
        ensure
          session.close
        end
        print_table(COLUMNS, rows)
        ::Pupgrade.logger.info("compile: #{rows.size - failed} compiled, #{failed} failed; written to #{out}")
        exit(failed.zero? ? 0 : 1)
      end

      protected

      def configure_parser(o)
        o.on('-d', '--repo-dir=DIR', 'Path to the deployed control repo environment',
             "Default: '.' (if environment.conf and hiera.yaml exist)") { |v| @options[:repo_dir] = v }
        o.on('--factsets=PATH', Array, 'Factset files or directories, comma-separated, repeatable',
             '(config: compile.factsets)') { |v| accumulate(:factsets, v) }
        o.on('-o', '--output-dir=DIR', 'Where to write OUT/<certname>/ (config: compile.output_dir)') { |v| @options[:output_dir] = v }
        o.on('--certname=GLOBS', Array, 'Only factsets whose certname matches (case-insensitive)') { |v| accumulate(:certnames, v) }

        o.separator ''
        o.separator 'What to compile:'
        o.on('--environment=NAME', 'Environment name (config: compile.environment)') { |v| @options[:environment] = v }
        o.on('--manifest=PATH', 'A manifest file or directory in place of environment.conf\'s (config: compile.manifest)') { |v| @options[:manifest] = v }
        o.on('--code=CODE', 'Puppet code compiled in place of the manifest') { |v| @options[:code] = v }
        o.on('--prepend=CODE', 'Puppet code evaluated before the manifest; @FILE reads it from a file',
             '(config: compile.prepend_file names the file)') { |v| @options[:prepend] = v }
        o.on('--var=NAME=VALUE', 'A top-scope variable, repeatable (config: compile.vars)') { |v| pair(:vars, v) }
        o.on('--server-fact=NAME=VALUE', 'An entry of $server_facts, repeatable (config: compile.server_facts)') { |v| pair(:server_facts, v) }

        o.separator ''
        o.separator 'The execution guard:'
        o.on('--stubs=FILE', 'YAML answering commands and facts module code asks for (config: compile.stubs)') { |v| @options[:stubs] = v }
        o.on('--on-leak=POLICY', ::Pupgrade::Compile::Session::ON_LEAK,
             'For a command the stubs do not answer: raise (default) or allow (config: compile.on_leak)') { |v| @options[:on_leak] = v }

        o.separator ''
        o.separator 'Writes OUT/<certname>/catalog.json (Puppet\'s catalog data, sorted) and probes.json'
        o.separator '(functions, facts, lookups, providers, warnings, deprecations, leaks). Exits 1 when a'
        o.separator 'compile fails; its error is in OUT/<certname>/error.txt.'
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
        stubs = @options[:stubs] ? ::Pupgrade::Compile::Stubs.load(File.expand_path(@options[:stubs], repo.dir)) : ::Pupgrade::Compile::Stubs.empty
        prepend = @options[:prepend]
        prepend = "@#{@options[:prepend_file]}" if prepend.nil? && @options[:prepend_file]
        prepend = File.read(File.expand_path(prepend.delete_prefix('@'), repo.dir)) if prepend&.start_with?('@')
        ::Pupgrade::Compile::Session.new(
          repo_dir: repo.dir, environment: @options[:environment], manifest: @options[:manifest], code: @options[:code],
          prepend: prepend, vars: @options[:vars] || {}, server_facts: @options[:server_facts] || {},
          stubs: stubs, on_leak: @options[:on_leak],
        ).start
      rescue ::Pupgrade::Compile::Session::Error, ::Pupgrade::Compile::Stubs::Error, Errno::ENOENT => e
        fatal!("compile: #{e.message}", 3)
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

      def probes_document(result)
        {
          'document'       => 'probes',
          'schema_version' => 1,
          'certname'       => result.certname,
          'factset'        => result.factset.path,
          'environment'    => @options[:environment],
          'status'         => result.ok? ? 'ok' : 'failed',
          'error'          => result.error,
          'seconds'        => result.seconds.round(3),
        }.compact.merge(result.probes)
      end

      def row(result)
        p = result.probes
        [result.certname,
         result.catalog ? result.catalog['resources'].size.to_s : '-',
         result.catalog ? result.catalog['classes'].size.to_s : '-',
         (p['warnings'].size + p['deprecations'].size).to_s,
         p['leaks'].size.to_s,
         result.ok? ? 'ok' : 'failed']
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
          output_dir:   cfg.dig('compile', 'output_dir') || 'pupgrade-catalogs',
          environment:  cfg.dig('compile', 'environment') || 'production',
          manifest:     cfg.dig('compile', 'manifest'),
          prepend_file: cfg.dig('compile', 'prepend_file'),
          stubs:        cfg.dig('compile', 'stubs'),
          on_leak:      cfg.dig('compile', 'on_leak') || 'raise',
          vars:         cfg.dig('compile', 'vars'),
          server_facts: cfg.dig('compile', 'server_facts'),
        }.compact
      end
    end
  end
end

Dir[File.join(__dir__, 'compile', '*.rb')].sort.each { |f| require f }
