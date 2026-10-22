require 'fileutils'
require 'json'
require 'open3'

require 'driftless/inputs/module_metadata'
require 'driftless/module_inventory'
require 'pupgrade/surface'

module Pupgrade
  module Surface
    # What `surface` and `module diff` are pointed at, and how each becomes
    # a document: a module directory, a module on the control repo's
    # modulepath by name, either at a ref of its own clone, a document file,
    # or a git remote at a ref. Documents are kept in a cache directory,
    # named by module, version, and ref, and read from there unless refreshed.
    class Targets
      class Error < StandardError; end

      # One thing to read.
      #
      # @!attribute [r] spec
      #   @return [String] as given
      # @!attribute [r] dir
      #   @return [String, nil] the module directory; nil for a file or a remote
      # @!attribute [r] ref
      #   @return [String, nil] a ref of the directory's clone or of the remote
      # @!attribute [r] file
      #   @return [String, nil] a document file
      # @!attribute [r] git
      #   @return [String, nil] a remote URL
      Target = Data.define(:spec, :dir, :ref, :file, :git) do
        def initialize(dir: nil, ref: nil, file: nil, git: nil, **rest)
          super
        end
      end

      # @param repo_dir [String, nil] the control repo, for names and the modulepath
      # @param cache_dir [String] where documents are kept
      # @param fetch [Boolean] whether to fetch a clone's origin before reading a ref
      # @param refresh [Boolean] whether to read again what the cache holds
      # @param logger [#debug, #info]
      def initialize(repo_dir: nil, cache_dir:, fetch: false, refresh: false, logger: Pupgrade.logger)
        @repo_dir  = repo_dir && File.expand_path(repo_dir)
        @cache_dir = File.expand_path(cache_dir, @repo_dir || Dir.pwd)
        @fetch     = fetch
        @refresh   = refresh
        @logger    = logger
      end

      # @return [Driftless::ModuleInventory, nil]
      def inventory
        return nil unless @repo_dir

        @inventory ||= ::Driftless::ModuleInventory.new(@repo_dir)
      end

      # @return [Array<String>] the repo's module directories, from where its
      #   modules sit
      def modulepath
        return [] unless inventory

        inventory.entries.map { |e| File.expand_path(File.dirname(e.path), @repo_dir) }.uniq
      end

      # Every module on the repo's modulepath, as targets.
      #
      # @return [Array<Target>]
      def all
        raise Error, 'reading every module needs a control repo (--repo-dir)' unless inventory

        inventory.entries.select { |e| e.metadata.name && File.directory?(File.expand_path(e.path, @repo_dir)) }
                 .map { |e| Target.new(spec: e.path, dir: File.expand_path(e.path, @repo_dir)) }
      end

      # @param spec [String] `DIR`, `DIR:REF`, `NAME`, `NAME:REF`, or a document file
      # @param ref [String, nil] a ref for a spec that names none
      # @return [Target]
      # @raise [Error] when nothing answers to the spec
      def resolve(spec, ref: nil)
        return Target.new(spec: spec, file: File.expand_path(spec)) if File.file?(spec)

        path, given = split_ref(spec)
        ref = given || ref
        if File.directory?(path)
          return Target.new(spec: spec, dir: File.expand_path(path), ref: ref)
        end

        entry = inventory&.find(path)
        raise Error, "#{path}: no such directory, and #{inventory ? 'no such module on the modulepath' : 'no control repo to look it up in (--repo-dir)'}" unless entry

        dir = File.expand_path(entry.path, @repo_dir)
        raise Error, "#{entry.path}: not deployed" unless File.directory?(dir)

        Target.new(spec: spec, dir: dir, ref: ref)
      end

      # @param url [String]
      # @param ref [String]
      # @return [Target]
      def remote(url, ref)
        Target.new(spec: "#{url}@#{ref}", git: url, ref: ref)
      end

      # The target's document: a file as it is, else from the cache when it
      # is there and not refreshed, else extracted and cached.
      #
      # @return [Array(Hash, String, Boolean)] the document, the file it is
      #   in, and whether it was read from the cache
      def document(target)
        return [Surface.load(target.file), target.file, false] if target.file

        path = cache_path(target)
        if path && File.file?(path) && !@refresh
          @logger.info("surface: #{target.spec}: cached at #{path}")
          return [Surface.load(path), path, true]
        end

        doc = extract(target)
        Array(doc['errors']).each { |e| @logger.warn("surface: #{target.spec}: #{e}") }
        path ||= cache_path_for(doc, target)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(doc) + "\n")
        @logger.info("surface: #{target.spec}: wrote #{path}")
        [doc, path, false]
      rescue Surface::Error => e
        raise Error, e.message
      end

      private

      # "stdlib:v9.0.0" splits at the last colon; a Windows-free world lets
      # a path keep its colons only when nothing follows that could be a ref.
      def split_ref(spec)
        base, sep, ref = spec.rpartition(':')
        return [spec, nil] if sep.empty? || ref.empty? || ref.include?('/') && File.exist?(spec)

        [base, ref]
      end

      # A shallow checkout has no tag of its own, so the ref read at is
      # written into the document's source.
      def extract(target)
        if target.git
          @logger.info("surface: fetching #{target.git} at #{target.ref}")
          return at_ref(target.git, target.ref)
        end
        if target.ref
          fetch!(target.dir) if @fetch
          @logger.info("surface: reading #{target.dir} at #{target.ref}")
          return at_ref(target.dir, target.ref)
        end
        @logger.info("surface: reading #{target.dir}")
        Surface.extract(target.dir, modulepath: modulepath)
      end

      def at_ref(url, ref)
        doc = Surface.checkout(url, ref) { |dir| Surface.extract(dir, modulepath: modulepath) }
        doc['source'] = (doc['source'] || {}).merge('ref' => ref, 'from' => url)
        doc
      end

      def fetch!(dir)
        @logger.info("surface: #{dir}: fetching origin")
        _out, err, status = Open3.capture3({ 'GIT_TERMINAL_PROMPT' => '0' }, 'git', '-C', dir, 'fetch', '--quiet', '--tags', 'origin')
        raise Error, "#{dir}: fetch failed: #{err.lines.last.to_s.strip}" unless status.success?
      end

      # The cache file for a target whose version is known before reading:
      # a directory's metadata, or the metadata at the ref in its clone.
      #
      # @return [String, nil] nil when the version is not known yet
      def cache_path(target)
        return nil if target.git

        text =
          if target.ref
            out, _err, status = Open3.capture3('git', '-C', target.dir, 'show', "#{target.ref}:metadata.json")
            status.success? ? out : nil
          elsif File.file?(File.join(target.dir, 'metadata.json'))
            File.read(File.join(target.dir, 'metadata.json'))
          end
        return nil unless text

        metadata = ::Driftless::Inputs::ModuleMetadata.parse(text, path: 'metadata.json')
        return nil if metadata.error || metadata.name.nil?

        File.join(@cache_dir, file_name(metadata.name, metadata.version, target.ref))
      end

      def cache_path_for(doc, target)
        name = doc.dig('module', 'name') || File.basename(target.dir || target.git.to_s, '.git')
        File.join(@cache_dir, file_name(name, doc.dig('module', 'version'), target.ref))
      end

      # "stdlib-9.6.0--v9.6.0.json": the module's short name, its version,
      # and the ref it was read at when one was given.
      def file_name(name, version, ref)
        short = name.to_s.split(%r{[-/]}).last
        parts = [short, version || 'unversioned']
        base  = parts.join('-')
        base += "--#{ref.to_s.tr('/', '_')}" if ref
        "#{base}.json"
      end
    end
  end
end
