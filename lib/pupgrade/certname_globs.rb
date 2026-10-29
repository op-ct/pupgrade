module Pupgrade
  # Matches a node's certname against `--certname` globs, case-insensitive.
  # A glob starting with `!` leaves out the certnames it matches; a
  # certname passes when it matches some plain glob (or none are given) and
  # no `!` glob.
  module CertnameGlobs
    FLAGS = File::FNM_CASEFOLD

    module_function

    # @param globs [Array<String>, nil]
    # @param certname [String]
    # @return [Boolean]
    def match?(globs, certname)
      without, with = Array(globs).partition { |g| g.start_with?('!') }
      (with.empty? || with.any? { |g| File.fnmatch?(g, certname, FLAGS) }) &&
        without.none? { |g| File.fnmatch?(g.delete_prefix('!'), certname, FLAGS) }
    end
  end
end
