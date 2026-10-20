require 'open3'
require 'semantic_puppet'

require 'driftless/inputs/module_metadata'
require 'pupgrade/inputs/branchfile'

module Pupgrade
  module Solve
    # The versions a deployed git module could move to, read from its clone:
    # the tags past its current version, on its tracking branch when one is
    # known, and the branch's tip when asked for. Each carries the
    # metadata.json at that ref.
    class Candidates
      # One version a module could be at.
      #
      # @!attribute [r] ref
      #   @return [String] the tag, or the branch for its tip
      # @!attribute [r] ref_type
      #   @return [String] "tag" or "branch", as a Puppetfile would declare it
      # @!attribute [r] version
      #   @return [SemanticPuppet::Version, nil] from the tag name for a tag,
      #     else from the metadata
      # @!attribute [r] metadata
      #   @return [Driftless::Inputs::ModuleMetadata::Result]
      # @!attribute [r] current
      #   @return [Boolean] the version deployed now
      Candidate = Data.define(:ref, :ref_type, :version, :metadata, :current) do
        def to_s
          current ? "#{ref} (current)" : ref
        end
      end

      # Why a module has no candidates besides its current version.
      Unsolvable = Data.define(:reason)

      # @param repo_dir [String] the control repo
      # @param branchfile [String, nil] the branchfile naming tracking
      #   branches, relative to the repo
      # @param include_heads [Boolean] whether a tracking branch's tip is a
      #   candidate for a tag-pinned module
      # @param fetch [Boolean] whether to fetch each clone's origin first
      def initialize(repo_dir, branchfile: nil, include_heads: false, fetch: false)
        @repo_dir      = File.expand_path(repo_dir)
        @include_heads = include_heads
        @fetch         = fetch
        @branches      = branchfile ? Inputs::Branchfile.load(File.expand_path(branchfile, @repo_dir)) : nil
        @warnings      = []
      end

      # @return [Array<String>]
      attr_reader :warnings

      # @param entry [Driftless::ModuleInventory::Entry]
      # @return [Array<Candidate>, Unsolvable] oldest first, the current
      #   version first of all
      def for(entry)
        declared = entry.declared
        return Unsolvable.new(reason: 'not in the Puppetfile') unless declared
        return Unsolvable.new(reason: 'Forge module') unless declared.git

        dir = File.join(@repo_dir, entry.path)
        return Unsolvable.new(reason: 'not deployed') unless File.directory?(dir)
        return Unsolvable.new(reason: 'not a git clone') unless File.exist?(File.join(dir, '.git'))

        fetch(dir, entry) if @fetch
        current = Candidate.new(ref: declared.ref.to_s, ref_type: declared.ref_type || 'ref', version: parse(entry.metadata.version),
                                metadata: entry.metadata, current: true)
        branch  = tracking_branch(entry)
        if declared.ref_type == 'branch'
          tip = tip_of(dir, declared.ref.to_s, entry)
          return [current] if tip.nil? || at_head?(dir, declared.ref.to_s)

          return [current, tip]
        end

        tags = tags_past(dir, current.version, branch, entry)
        tips = (@include_heads && branch) ? [tip_of(dir, branch, entry)].compact : []
        [current] + tags + tips
      end

      private

      # @return [String, nil] the branch a branchfile names for the module
      def tracking_branch(entry)
        return nil unless @branches

        if @branches.error
          @warnings << "branchfile: #{@branches.error}" unless @warnings.include?("branchfile: #{@branches.error}")
          return nil
        end
        [entry.declared&.name, entry.metadata.name, File.basename(entry.path)].compact.filter_map { |n| @branches.branch_for(n) }.first
      end

      # Tags whose version is past the current one: on the branch when one
      # is known, else any tag of the clone.
      def tags_past(dir, current_version, branch, entry)
        args = ['tag', '--list']
        args.push('--merged', ref_in_clone(dir, branch)) if branch && ref_in_clone(dir, branch)
        out = git(dir, *args)
        return [] unless out

        out.split("\n").filter_map { |tag|
          version = parse(tag.sub(/\Av/, ''))
          next if version.nil? || (current_version && version <= current_version)

          metadata = metadata_at(dir, tag, entry)
          next unless metadata

          Candidate.new(ref: tag, ref_type: 'tag', version: version, metadata: metadata, current: false)
        }.sort_by(&:version)
      end

      def tip_of(dir, branch, entry)
        ref = ref_in_clone(dir, branch)
        return nil unless ref

        metadata = metadata_at(dir, ref, entry)
        return nil unless metadata

        Candidate.new(ref: branch, ref_type: 'branch', version: parse(metadata.version), metadata: metadata, current: false)
      end

      # Whether the clone's HEAD is the branch's tip already.
      def at_head?(dir, branch)
        ref = ref_in_clone(dir, branch)
        ref && git(dir, 'rev-parse', ref) == git(dir, 'rev-parse', 'HEAD')
      end

      # The branch as the clone knows it: its remote-tracking ref first.
      def ref_in_clone(dir, branch)
        ["origin/#{branch}", branch].find { |r| git(dir, 'rev-parse', '--verify', '--quiet', "#{r}^{commit}") }
      end

      def metadata_at(dir, ref, entry)
        text = git(dir, 'show', "#{ref}:#{::Driftless::Inputs::ModuleMetadata::FILENAME}")
        if text.nil?
          @warnings << "#{entry.path}: no metadata.json at #{ref}; skipped"
          return nil
        end
        metadata = ::Driftless::Inputs::ModuleMetadata.parse(text, path: "#{entry.path}@#{ref}:metadata.json")
        if metadata.error
          @warnings << "#{entry.path}: #{metadata.error}; #{ref} skipped"
          return nil
        end
        metadata
      end

      def fetch(dir, entry)
        @warnings << "#{entry.path}: fetch failed" if git(dir, 'fetch', '--quiet', '--tags', 'origin').nil?
      end

      def parse(version)
        SemanticPuppet::Version.parse(version.to_s)
      rescue SemanticPuppet::Version::ValidationFailure
        nil
      end

      def git(dir, *args)
        out, _err, status = Open3.capture3({ 'GIT_TERMINAL_PROMPT' => '0' }, 'git', '-C', dir, *args)
        status.success? ? out.strip : nil
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
