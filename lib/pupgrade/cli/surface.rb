require 'json'

require 'pupgrade/cli/base'
require 'pupgrade/cli/root'
require 'pupgrade/surface'

module Pupgrade
  module CLI
    # `pupgrade surface`
    #
    # One module's API surfaces as a JSON document: a module directory, or
    # a ref of a git remote. `surface diff` compares two.
    class Surface < Base
      register_command name: 'surface', subcommand_of: Root
      positional '[<module-dir>]'
      desc 'Write a module\'s API surfaces (classes, functions, types, providers, facts) as JSON; `diff` compares two'
      runs_without_subcommand
      skip_config_load

      def execute(argv)
        reject_extra_args!(argv, max: 1)
        dir = argv.first
        fatal!('surface takes a module directory, or --git URL --ref REF', help: true) if dir.nil? == @options[:git].nil?
        fatal!('surface: --git needs --ref', help: true) if @options[:git] && @options[:ref].nil?

        document =
          if dir
            ::Pupgrade::Surface.extract(dir)
          else
            ::Pupgrade::Surface.checkout(@options[:git], @options[:ref]) { |checkout| ::Pupgrade::Surface.extract(checkout) }
          end
        document['source'] = dir ? File.expand_path(dir) : "#{@options[:git]}@#{@options[:ref]}"
        text = JSON.pretty_generate(document) + "\n"
        if @options[:output]
          File.write(File.expand_path(@options[:output]), text)
          puts File.expand_path(@options[:output])
        else
          print text
        end
        document['errors'].each { |e| ::Pupgrade.logger.warn("surface: #{e}") }
        ::Pupgrade.logger.info("surface: #{document.dig('module', 'name') || '(unnamed)'} #{document.dig('module', 'version')}: " \
                               "#{::Pupgrade::Surface::Diff::SECTIONS.map { |s| "#{document[s].size} #{s.tr('_', ' ')}" }.join(', ')}")
        exit 0
      rescue ::Pupgrade::Surface::Error => e
        fatal!("surface: #{e.message}", 3)
      end

      protected

      def configure_parser(o)
        o.on('-o', '--output=FILE', 'Write the document to FILE instead of stdout') { |v| @options[:output] = v }
        o.on('--git=URL', 'Read the module at --ref of this git remote instead of a directory') { |v| @options[:git] = v }
        o.on('--ref=REF', 'The tag, branch, or sha to read at --git') { |v| @options[:ref] = v }
        o.separator ''
        o.separator 'Loading a module\'s Ruby is how its functions, types, providers, and facts are read,'
        o.separator 'so extraction runs in a process of its own. Files that fail to load are listed'
        o.separator 'under "errors" in the document and warned about.'
      end
    end
  end
end

Dir[File.join(__dir__, 'surface', '*.rb')].sort.each { |f| require f }
