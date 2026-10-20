module Pupgrade
  module Compile
    # Which module on a modulepath provides a resource type, a provider, or
    # a fact, from the files it ships, and which module a manifest path
    # belongs to. Names only; signatures are `surface`'s job.
    class ModuleIndex
      # What declares a fact in a module's lib/facter: `Facter.add(:name)` or
      # `Facter.add('name')`.
      FACT_DECLARATION = /Facter\.add\(\s*(?::|['"])([A-Za-z0-9_]+)['"]?/.freeze

      # @param modulepath [Array<String>] absolute module directories, in
      #   search order
      def initialize(modulepath)
        @dirs      = modulepath.map { |d| File.expand_path(d) }
        @types     = {}
        @providers = {}
        @facts     = {}
        @aliases   = {}
        scan
      end

      # @param name [String, Symbol] a resource type
      # @return [String, nil] the module shipping lib/puppet/type/<name>.rb
      def type(name)
        @types[name.to_s.downcase]
      end

      # @param type [String, Symbol]
      # @param provider [String, Symbol]
      # @return [String, nil] the module shipping lib/puppet/provider/<type>/<provider>.rb
      def provider(type, provider)
        @providers["#{type.to_s.downcase}/#{provider.to_s.downcase}"]
      end

      # @param name [String] a type alias, e.g. "Stdlib::Port"
      # @return [String, nil] the module shipping types/<path>.pp for it
      def type_alias(name)
        @aliases[name.to_s.downcase]
      end

      # @param name [String] a fact, by its top-level name
      # @return [String, nil] the module whose lib/facter or facts.d declares it
      def fact(name)
        @facts[name.to_s.downcase.split('.').first]
      end

      # @param path [String] a file under some module
      # @return [String, nil] the module's directory name
      def module_of(path)
        return nil unless path

        full = File.expand_path(path)
        dir  = @dirs.find { |d| full.start_with?("#{d}/") }
        return nil unless dir

        full.delete_prefix("#{dir}/").split('/').first
      end

      private

      def scan
        @dirs.each do |dir|
          Dir.children(dir).sort.each do |mod|
            root = File.join(dir, mod)
            next unless File.directory?(root)

            Dir.glob(File.join(root, 'lib/puppet/type/*.rb')).each { |f| @types[File.basename(f, '.rb')] ||= mod }
            Dir.glob(File.join(root, 'lib/puppet/provider/*/*.rb')).each do |f|
              @providers["#{File.basename(File.dirname(f))}/#{File.basename(f, '.rb')}"] ||= mod
            end
            Dir.glob(File.join(root, 'lib/facter/**/*.rb')).each do |f|
              File.read(f).scan(FACT_DECLARATION) { |(name)| @facts[name.downcase] ||= mod }
            rescue SystemCallError
              nil
            end
            Dir.glob(File.join(root, 'facts.d/*')).each { |f| @facts[File.basename(f, File.extname(f)).downcase] ||= mod }
            Dir.glob(File.join(root, 'types/**/*.pp')).each do |f|
              segments = f.delete_prefix("#{root}/types/").delete_suffix('.pp').split('/')
              @aliases[([mod] + segments).join('::').downcase] ||= mod
            end
          end
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
