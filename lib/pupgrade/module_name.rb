module Pupgrade
  # Matches a glob against a module's name. A module is known by its
  # short name (`fips`): that is what a modulepath holds one of, and owners
  # vary between a Puppetfile, a dependent's metadata, and the module's own
  # (`voxpupuli-firewalld`, `puppet/firewalld`). So a glob matches the
  # short name, whatever owner either side carries, except that a glob
  # which says nothing of the module, `puppet-*` or `*-stdlib`, matches the
  # full name as written: the one way to say "owned by". Case-insensitive.
  module ModuleName
    FLAGS = File::FNM_CASEFOLD

    module_function

    # @return [String] "owner-module", lowercase
    def normalize(name)
      name.to_s.tr('/', '-').downcase
    end

    # @return [String] the part after the owner, or the whole name without one
    def short(name)
      normalize(name).split('-', 2).last
    end

    # @param glob [String]
    # @param names [Array<String, nil>] the module's spellings; nils are skipped
    # @return [Boolean]
    def match?(glob, *names)
      pattern = normalize(glob)
      owner, dash, rest = pattern.partition('-')
      by_owner = !dash.empty? && (owner.match?(/[*?\[]/) || rest.match?(/\A[*?]+\z/))
      names.compact.any? do |name|
        full = normalize(name)
        by_owner ? File.fnmatch?(pattern, full, FLAGS) : File.fnmatch?(short(pattern), short(full), FLAGS)
      end
    end

    # Whether any glob in the list matches.
    def any?(globs, *names)
      Array(globs).any? { |g| match?(g, *names) }
    end
  end
end
