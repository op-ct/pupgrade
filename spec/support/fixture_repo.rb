require 'fileutils'
require 'json'
require 'time'

module Pupgrade
  # A control repo to run pupgrade against, built from a fixed catalogue:
  # bare git remotes with one commit and tag per release of each module, a
  # deployed environment with every module cloned at the tag its Puppetfile
  # declares, two Forge-style modules on disk, a pupgrade.yaml, and a
  # Puppetfile.proposed that bumps stdlib a major version and a few modules
  # with it. The current state has every conflict kind; the proposal
  # introduces many more and resolves a few.
  #
  # Commits carry fixed authors and dates, so two builds give the same shas.
  class FixtureRepo
    # One release of a module: what its metadata.json declares.
    #
    # @!attribute [r] version
    #   @return [String]
    # @!attribute [r] dependencies
    #   @return [Hash{String => String}] dependency name to version range
    # @!attribute [r] puppet
    #   @return [String] the puppet requirement range
    # @!attribute [r] operatingsystems
    #   @return [Hash{String => Array<String>}] OS name to releases
    Release = Data.define(:version, :dependencies, :puppet, :operatingsystems)

    # One module of the catalogue.
    #
    # @!attribute [r] name
    #   @return [String] "owner-module"
    # @!attribute [r] releases
    #   @return [Array<Release>] oldest first; nil for a Forge module
    # @!attribute [r] deployed
    #   @return [String] the version the Puppetfile pins and the clone sits
    #     at; the Forge version for a Forge module
    # @!attribute [r] branch
    #   @return [String] the branch releases are tagged on
    # @!attribute [r] unreleased
    #   @return [Boolean] whether the branch has a commit past the last tag
    # @!attribute [r] tag_prefix
    #   @return [String] "v" for tags like v1.2.3, "" for 1.2.3
    # @!attribute [r] forge
    #   @return [Boolean] a Forge entry: a directory with metadata.json, no
    #     remote
    # @!attribute [r] track
    #   @return [Boolean] the Puppetfile follows the branch, not a tag
    Mod = Data.define(:name, :releases, :deployed, :branch, :unreleased, :tag_prefix, :forge, :track) do
      def initialize(branch: 'main', unreleased: false, tag_prefix: 'v', forge: false, track: false, **rest)
        super
      end

      def owner
        name.split('-', 2).first
      end

      def short
        name.split('-', 2).last
      end

      def tag(version)
        "#{tag_prefix}#{version}"
      end

      def release(version)
        releases.find { |r| r.version == version } or raise ArgumentError, "#{name}: no release #{version}"
      end
    end

    # What {FixtureRepo.build} returns.
    #
    # @!attribute [r] dir
    #   @return [String] the control repo (environment) directory
    # @!attribute [r] remotes_dir
    #   @return [String] where the bare module remotes are
    # @!attribute [r] puppetfile
    #   @return [String] the deployed Puppetfile
    # @!attribute [r] proposed
    #   @return [String] Puppetfile.proposed
    # @!attribute [r] config
    #   @return [String] pupgrade.yaml
    Result = Data.define(:dir, :remotes_dir, :puppetfile, :proposed, :config)

    OS_EL_OLD = { 'RedHat' => %w[7 8], 'CentOS' => %w[7], 'Ubuntu' => %w[18.04 20.04], 'Debian' => %w[10 11] }.freeze
    OS_EL     = { 'RedHat' => %w[8 9], 'Rocky' => %w[8 9], 'Ubuntu' => %w[20.04 22.04], 'Debian' => %w[11 12] }.freeze
    OS_DEB    = { 'Ubuntu' => %w[20.04 22.04], 'Debian' => %w[11 12] }.freeze
    OS_RH     = { 'RedHat' => %w[7 8 9], 'CentOS' => %w[7], 'OracleLinux' => %w[7 8 9] }.freeze
    OS_FOSS   = { 'Rocky' => %w[8 9], 'AlmaLinux' => %w[8 9], 'CentOS' => %w[7] }.freeze

    STDLIB_OLD = '>= 4.13.1 < 9.0.0'.freeze
    STDLIB_NEW = '>= 9.0.0 < 10.0.0'.freeze
    PUPPET_OLD = '>= 6.0.0 < 8.0.0'.freeze
    PUPPET_MID = '>= 7.0.0 < 9.0.0'.freeze
    PUPPET_NEW = '>= 8.0.0 < 9.0.0'.freeze

    def self.rel(version, deps = {}, puppet: PUPPET_MID, os: OS_EL_OLD)
      Release.new(version: version, dependencies: deps, puppet: puppet, operatingsystems: os)
    end

    def self.mod(name, releases, **opts)
      Mod.new(name: name, releases: releases, **opts)
    end

    # The modules, their release histories, and where each is deployed.
    # Old releases depend on stdlib < 9 and new ones on stdlib >= 9, which
    # is the knot a stdlib major bump ties.
    CATALOGUE = [
      mod('puppetlabs-stdlib', [
        rel('8.6.0'), rel('9.0.0', os: OS_EL), rel('9.4.0', os: OS_EL), rel('9.6.0', os: OS_EL),
      ], deployed: '8.6.0'),
      mod('puppetlabs-concat', [
        rel('7.3.0', { 'puppetlabs/stdlib' => STDLIB_OLD }),
        rel('9.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_EL),
        rel('9.1.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_EL),
      ], deployed: '7.3.0'),
      mod('puppetlabs-apt', [
        rel('8.5.0', { 'puppetlabs/stdlib' => STDLIB_OLD }, os: OS_DEB),
        rel('9.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_DEB),
        rel('9.4.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_DEB),
      ], deployed: '8.5.0'),
      mod('puppetlabs-inifile', [
        rel('5.4.0', { 'puppetlabs/stdlib' => STDLIB_OLD }),
        rel('6.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_EL),
        rel('6.1.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_EL),
      ], deployed: '5.4.0'),
      mod('puppetlabs-apache', [
        rel('10.1.1', { 'puppetlabs/stdlib' => STDLIB_OLD, 'puppetlabs/concat' => '>= 6.4.0 < 8.0.0' }),
        rel('11.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/concat' => '>= 9.0.0 < 10.0.0' }, os: OS_EL),
        rel('12.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/concat' => '>= 9.0.0 < 10.0.0' }, puppet: PUPPET_NEW, os: OS_EL),
      ], deployed: '10.1.1', unreleased: true),
      mod('puppetlabs-postgresql', [
        rel('8.3.0', { 'puppetlabs/stdlib' => STDLIB_OLD, 'puppetlabs/concat' => '>= 4.1.0 < 8.0.0', 'puppetlabs/apt' => '>= 2.0.0 < 9.0.0' }),
        rel('9.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/concat' => '>= 9.0.0 < 10.0.0', 'puppetlabs/apt' => '>= 9.0.0 < 10.0.0' }, os: OS_EL),
        rel('10.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/concat' => '>= 9.0.0 < 10.0.0', 'puppetlabs/apt' => '>= 9.0.0 < 10.0.0' }, puppet: PUPPET_NEW, os: OS_EL),
      ], deployed: '8.3.0'),
      mod('puppetlabs-mysql', [
        rel('13.3.0', { 'puppetlabs/stdlib' => STDLIB_OLD }),
        rel('15.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_EL),
      ], deployed: '13.3.0'),
      mod('puppetlabs-firewall', [
        rel('5.0.0', { 'puppetlabs/stdlib' => STDLIB_OLD }, puppet: PUPPET_OLD),
        rel('6.0.0', { 'puppetlabs/stdlib' => STDLIB_OLD }),
        rel('7.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_EL),
        rel('8.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, puppet: PUPPET_NEW, os: OS_EL),
      ], deployed: '5.0.0'),
      mod('puppetlabs-ntp', [
        rel('9.2.0', { 'puppetlabs/stdlib' => STDLIB_OLD }),
        rel('10.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_EL),
        rel('10.1.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_EL),
      ], deployed: '9.2.0'),
      mod('puppetlabs-motd', [
        rel('6.3.0', { 'puppetlabs/stdlib' => STDLIB_OLD }),
        rel('7.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_EL),
      ], deployed: '6.3.0'),
      mod('puppetlabs-vcsrepo', [
        rel('5.4.0'), rel('6.0.0', os: OS_EL), rel('6.1.0', os: OS_EL),
      ], deployed: '5.4.0'),
      mod('puppetlabs-java', [
        rel('9.0.0', { 'puppetlabs/stdlib' => STDLIB_OLD }),
        rel('10.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_EL),
        rel('11.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_EL),
      ], deployed: '9.0.0'),
      mod('puppetlabs-puppetdb', [
        rel('7.13.0', { 'puppetlabs/stdlib' => STDLIB_OLD, 'puppetlabs/postgresql' => '>= 6.5.0 < 9.0.0',
                      'puppetlabs/firewall' => '>= 1.1.3 < 6.0.0', 'puppetlabs/inifile' => '>= 1.1.3 < 6.0.0' }),
        rel('8.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/postgresql' => '>= 9.0.0 < 11.0.0',
                       'puppetlabs/firewall' => '>= 7.0.0 < 9.0.0', 'puppetlabs/inifile' => '>= 6.0.0 < 7.0.0' }, os: OS_EL),
        rel('8.1.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/postgresql' => '>= 9.0.0 < 11.0.0',
                       'puppetlabs/firewall' => '>= 7.0.0 < 9.0.0', 'puppetlabs/inifile' => '>= 6.0.0 < 7.0.0' }, os: OS_EL),
      ], deployed: '7.13.0'),
      mod('puppetlabs-tomcat', [
        rel('6.3.0', { 'puppetlabs/stdlib' => STDLIB_OLD, 'puppetlabs/concat' => '>= 1.1.1 < 8.0.0' }),
        rel('7.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/concat' => '>= 9.0.0 < 10.0.0' }, os: OS_EL),
        rel('7.1.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/concat' => '>= 9.0.0 < 10.0.0' }, os: OS_EL),
      ], deployed: '7.0.0'),
      mod('puppetlabs-yumrepo_core', [rel('2.0.0'), rel('2.1.0', os: OS_EL)], deployed: '2.0.0'),
      mod('puppet-nginx', [
        rel('4.4.0', { 'puppetlabs/stdlib' => STDLIB_OLD, 'puppetlabs/concat' => '>= 4.1.0 < 8.0.0' }),
        rel('5.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/concat' => '>= 9.0.0 < 10.0.0' }, os: OS_EL),
        rel('6.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/concat' => '>= 9.0.0 < 10.0.0' }, puppet: PUPPET_NEW, os: OS_EL),
      ], deployed: '4.4.0', branch: 'master'),
      mod('puppet-archive', [
        rel('6.1.2', { 'puppetlabs/stdlib' => STDLIB_OLD }),
        rel('7.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_EL),
        rel('7.1.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_EL),
      ], deployed: '6.1.2', branch: 'master'),
      mod('puppet-systemd', [
        rel('4.2.0', { 'puppetlabs/stdlib' => STDLIB_OLD, 'puppetlabs/inifile' => '>= 4.0.0 < 6.0.0' }),
        rel('5.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/inifile' => '>= 6.0.0 < 7.0.0' }, os: OS_EL),
        rel('6.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/inifile' => '>= 6.0.0 < 7.0.0' }, puppet: PUPPET_NEW, os: OS_EL),
      ], deployed: '4.2.0', branch: 'master'),
      mod('puppet-epel', [
        rel('4.1.0', { 'puppetlabs/stdlib' => STDLIB_OLD }, os: OS_RH),
        rel('5.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_RH),
      ], deployed: '4.1.0', branch: 'master'),
      mod('puppet-selinux', [
        rel('3.4.0', { 'puppetlabs/stdlib' => STDLIB_OLD }, os: OS_RH),
        rel('4.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_RH),
        rel('4.1.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_RH),
      ], deployed: '3.4.0', branch: 'master', unreleased: true),
      mod('puppet-logrotate', [
        rel('6.0.0', { 'puppetlabs/stdlib' => STDLIB_OLD }),
        rel('7.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_EL),
      ], deployed: '6.0.0', branch: 'master'),
      mod('puppet-redis', [
        rel('8.8.0', { 'puppetlabs/stdlib' => STDLIB_OLD, 'puppetlabs/apt' => '>= 4.1.0 < 9.0.0' }),
        rel('9.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/apt' => '>= 9.0.0 < 10.0.0' }, os: OS_EL),
        rel('10.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/apt' => '>= 9.0.0 < 10.0.0' }, os: OS_EL),
      ], deployed: '8.8.0', branch: 'master'),
      mod('puppet-kafka', [
        rel('8.1.0', { 'puppetlabs/stdlib' => STDLIB_OLD, 'puppet/zookeeper' => '>= 0.5.0 < 2.0.0', 'puppet/archive' => '>= 4.0.0 < 7.0.0' }),
        rel('9.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppet/zookeeper' => '>= 1.0.0 < 2.0.0', 'puppet/archive' => '>= 7.0.0 < 8.0.0' }, os: OS_EL),
      ], deployed: '8.1.0', branch: 'master'),
      mod('puppet-letsencrypt', [
        rel('9.0.0', { 'puppetlabs/stdlib' => STDLIB_OLD, 'puppetlabs/vcsrepo' => '>= 3.0.0 < 6.0.0' }),
        rel('10.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/vcsrepo' => '>= 6.0.0 < 7.0.0' }, os: OS_EL),
        rel('11.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/vcsrepo' => '>= 6.0.0 < 7.0.0' }, puppet: PUPPET_NEW, os: OS_EL),
      ], deployed: '9.0.0', branch: 'master'),
      mod('puppet-python', [
        rel('6.4.0', { 'puppetlabs/stdlib' => STDLIB_OLD, 'puppet/epel' => '>= 3.0.0 < 5.0.0' }),
        rel('7.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppet/epel' => '>= 5.0.0 < 6.0.0' }, os: OS_EL),
      ], deployed: '6.4.0', branch: 'master'),
      mod('puppet-fail2ban', [
        rel('4.1.0', { 'puppetlabs/stdlib' => STDLIB_OLD }, os: OS_DEB),
        rel('5.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_DEB),
      ], deployed: '4.1.0', branch: 'master'),
      mod('saz-timezone', [
        rel('6.1.0', { 'puppetlabs/stdlib' => STDLIB_OLD }, puppet: PUPPET_OLD),
        rel('7.0.0', { 'puppetlabs/stdlib' => '>= 4.13.1 < 10.0.0' }, os: OS_EL),
      ], deployed: '6.1.0', branch: 'master', tag_prefix: ''),
      mod('saz-ssh', [
        rel('11.1.0', { 'puppetlabs/stdlib' => STDLIB_OLD, 'puppetlabs/concat' => '>= 6.0.0 < 8.0.0' }),
        rel('12.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/concat' => '>= 9.0.0 < 10.0.0' }, os: OS_EL),
        rel('13.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW, 'puppetlabs/concat' => '>= 9.0.0 < 10.0.0' }, puppet: PUPPET_NEW, os: OS_EL),
      ], deployed: '11.1.0', branch: 'master', tag_prefix: ''),
      mod('saz-sudo', [
        rel('7.0.2', { 'puppetlabs/stdlib' => STDLIB_OLD }),
        rel('8.0.0', { 'puppetlabs/stdlib' => STDLIB_NEW }, os: OS_EL),
      ], deployed: '7.0.2', branch: 'master', tag_prefix: ''),
      mod('simp-simplib', [
        rel('4.9.0', { 'puppetlabs/stdlib' => STDLIB_OLD }, os: OS_FOSS),
        rel('4.10.0', { 'puppetlabs/stdlib' => '>= 8.0.0 < 10.0.0' }, os: OS_FOSS),
      ], deployed: '4.9.0', branch: 'master', unreleased: true),
      mod('simp-pupmod', [
        rel('8.5.0', { 'puppetlabs/stdlib' => STDLIB_OLD, 'simp/simplib' => '>= 4.0.0 < 5.0.0' }, os: OS_FOSS),
        rel('8.6.0', { 'puppetlabs/stdlib' => '>= 8.0.0 < 10.0.0', 'simp/simplib' => '>= 4.0.0 < 5.0.0' }, os: OS_FOSS),
      ], deployed: '8.5.0', branch: 'master'),
      mod('acme-baseline', [
        rel('0.1.0', { 'puppetlabs/stdlib' => STDLIB_OLD, 'simp/simplib' => '>= 4.0.0 < 5.0.0', 'puppetlabs/firewall' => '>= 5.0.0 < 9.0.0' }),
      ], deployed: '0.1.0', unreleased: true, track: true),
      mod('puppetlabs-translate', nil, deployed: '2.2.0', forge: true),
      mod('puppetlabs-facts', nil, deployed: '1.4.0', forge: true),
    ].freeze

    # What Puppetfile.proposed moves, by module name to version.
    PROPOSED = {
      'puppetlabs-stdlib'     => '9.6.0',
      'puppetlabs-concat'     => '9.1.0',
      'puppetlabs-apt'        => '9.4.0',
      'puppetlabs-apache'     => '12.0.0',
      'puppetlabs-postgresql' => '10.0.0',
      'puppetlabs-puppetdb'   => '8.1.0',
    }.freeze

    # Forge modules' metadata, which has no remote to come from.
    FORGE = {
      'puppetlabs-translate' => rel('2.2.0', {}, puppet: '>= 4.10.0 < 8.0.0'),
      'puppetlabs-facts'     => rel('1.4.0', {}, puppet: '>= 6.0.0 < 9.0.0', os: OS_EL),
    }.freeze

    CONFIG = <<~YAML.freeze
      ---
      modules:
        operatingsystems:
          RedHat: ['8', '9']
          Ubuntu: ['22.04']
        requirements:
          puppet: '>= 8.0.0 < 9.0.0'
    YAML

    EPOCH = Time.utc(2024, 1, 1)

    # @param dir [String] an empty or absent directory
    # @return [Result]
    def self.build(dir)
      new(dir).build
    end

    def initialize(dir)
      @dir     = File.expand_path(dir)
      @remotes = File.join(@dir, 'remotes')
      @commits = 0
    end

    # @return [Result]
    # @raise [ArgumentError] when the directory is not empty
    def build
      raise ArgumentError, "#{@dir}: not empty" if File.directory?(@dir) && Dir.children(@dir).any?

      FileUtils.mkdir_p([@remotes, File.join(@dir, 'modules'), File.join(@dir, 'site-modules'), File.join(@dir, 'data')])
      write_environment
      CATALOGUE.each do |m|
        if m.forge
          write_forge(m)
        else
          build_remote(m)
          deploy(m)
        end
      end
      File.write(puppetfile_path, puppetfile(CATALOGUE.to_h { |m| [m.name, m.deployed] }))
      File.write(proposed_path, puppetfile(CATALOGUE.to_h { |m| [m.name, PROPOSED.fetch(m.name, m.deployed)] }))
      File.write(config_path, CONFIG)
      Result.new(dir: @dir, remotes_dir: @remotes, puppetfile: puppetfile_path, proposed: proposed_path, config: config_path)
    end

    private

    def puppetfile_path
      File.join(@dir, 'Puppetfile')
    end

    def proposed_path
      File.join(@dir, 'Puppetfile.proposed')
    end

    def config_path
      File.join(@dir, 'pupgrade.yaml')
    end

    def remote_url(mod)
      File.join(@remotes, "#{mod.name}.git")
    end

    def write_environment
      File.write(File.join(@dir, 'environment.conf'), "modulepath = site-modules:modules\n")
      File.write(File.join(@dir, 'hiera.yaml'), <<~YAML)
        ---
        version: 5
        defaults:
          datadir: data
          data_hash: yaml_data
        hierarchy:
          - name: common
            path: common.yaml
      YAML
      File.write(File.join(@dir, 'data/common.yaml'), "---\nprofile::base::ntp_servers:\n  - time.example.com\n")
      %w[profile role].each do |name|
        FileUtils.mkdir_p(File.join(@dir, 'site-modules', name, 'manifests'))
      end
      File.write(File.join(@dir, 'site-modules/profile/manifests/base.pp'),
                 "class profile::base (Array[String] $ntp_servers) {\n  class { 'ntp': servers => $ntp_servers }\n  include timezone\n}\n")
      File.write(File.join(@dir, 'site-modules/role/manifests/web.pp'),
                 "class role::web {\n  include profile::base\n  include apache\n}\n")
    end

    # One Puppetfile text: git modules at the given versions, Forge modules
    # at theirs, the tracking module on its branch.
    def puppetfile(versions)
      lines = ["forge 'https://forge.example.com'", '']
      CATALOGUE.each do |m|
        if m.forge
          lines << "mod '#{m.name}', '#{m.deployed}'"
        elsif m.track
          lines << "mod '#{m.name}',\n  git: '#{remote_url(m)}',\n  branch: '#{m.branch}'"
        else
          lines << "mod '#{m.name}',\n  git: '#{remote_url(m)}',\n  tag: '#{m.tag(versions.fetch(m.name))}'"
        end
      end
      lines.join("\n") + "\n"
    end

    def metadata(mod, release)
      {
        'name'         => mod.name,
        'version'      => release.version,
        'author'       => mod.owner,
        'summary'      => "Manages #{mod.short}",
        'license'      => 'Apache-2.0',
        'source'       => "https://git.example.com/#{mod.owner}/#{mod.short}.git",
        'dependencies' => release.dependencies.map { |name, range| { 'name' => name, 'version_requirement' => range } },
        'requirements' => [{ 'name' => 'puppet', 'version_requirement' => release.puppet }],
        'operatingsystem_support' => release.operatingsystems.map do |os, releases|
          { 'operatingsystem' => os, 'operatingsystemrelease' => releases }
        end,
      }
    end

    # Writes one release's files into a work tree.
    def write_release(dir, mod, release)
      FileUtils.mkdir_p(File.join(dir, 'manifests'))
      File.write(File.join(dir, 'metadata.json'), JSON.pretty_generate(metadata(mod, release)) + "\n")
      File.write(File.join(dir, 'manifests/init.pp'), "class #{mod.short} (\n  String $version = '#{release.version}',\n) {\n}\n")
      File.open(File.join(dir, 'CHANGELOG.md'), 'a') { |f| f.puts "## #{release.version}\n\n- Release #{release.version}\n" }
    end

    # A bare remote with one commit and tag per release on the module's
    # branch, and one more commit when the module has unreleased work.
    def build_remote(mod)
      work = File.join(@dir, '.build', mod.name)
      FileUtils.mkdir_p(work)
      git(work, 'init', '-q', '-b', mod.branch)
      mod.releases.each do |release|
        write_release(work, mod, release)
        commit(work, "Release #{release.version}")
        git(work, 'tag', '-a', '-m', "Release #{release.version}", mod.tag(release.version))
      end
      if mod.unreleased
        File.write(File.join(work, 'README.md'), "# #{mod.name}\n\nUnreleased fix.\n")
        commit(work, 'Fix a thing after the last release')
      end
      git(work, 'clone', '-q', '--bare', work, remote_url(mod))
      FileUtils.rm_rf(work)
    end

    # Clones the remote into modules/ and leaves it detached at the deployed
    # tag, or at the branch tip for a tracking module, as r10k would.
    def deploy(mod)
      target = File.join(@dir, 'modules', mod.short)
      git(@dir, 'clone', '-q', remote_url(mod), target)
      ref = mod.track ? "origin/#{mod.branch}" : mod.tag(mod.deployed)
      git(target, 'checkout', '-q', '--detach', ref)
    end

    def write_forge(mod)
      dir = File.join(@dir, 'modules', mod.short)
      write_release(dir, mod, FORGE.fetch(mod.name))
    end

    def commit(dir, message)
      @commits += 1
      stamp = (EPOCH + (@commits * 86_400)).iso8601
      git(dir, 'add', '-A')
      git(dir, 'commit', '-q', '-m', message, env: { 'GIT_AUTHOR_DATE' => stamp, 'GIT_COMMITTER_DATE' => stamp })
    end

    def git(dir, *args, env: {})
      system(env.merge('GIT_CONFIG_GLOBAL' => '/dev/null', 'GIT_CONFIG_SYSTEM' => '/dev/null'),
             'git', '-C', dir, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com',
             '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', '-c', 'init.defaultBranch=main',
             *args, exception: true)
    end
  end
end
