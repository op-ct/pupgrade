module Pupgrade
  # How a glob names a module. A module goes by up to three spellings:
  # `simp/fips` and `simp-fips` in metadata and Puppetfiles, and `fips`
  # on the modulepath and in conversation. A glob matches when it matches
  # the full name in either spelling or the short name, and a glob with an
  # owner also matches by its short part when the module declares no owner
  # at all. Globs are case-insensitive.
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
      names.compact.any? do |name|
        full = normalize(name)
        next true if File.fnmatch?(pattern, full, FLAGS) || File.fnmatch?(pattern, short(full), FLAGS)

        # "puppet-augeasproviders" against a module whose metadata says
        # only "augeasproviders"
        !full.include?('-') && !pattern.include?('*') && pattern.include?('-') && File.fnmatch?(short(pattern), full, FLAGS)
      end
    end

    # Whether any glob in the list matches.
    def any?(globs, *names)
      Array(globs).any? { |g| match?(g, *names) }
    end
  end
end
