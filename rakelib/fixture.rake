desc 'Build a fixture control repo (git module remotes, deployed clones, proposed Puppetfiles) into DIR; ' \
     'SCENARIO is a scenario directory (default: spec/fixtures/scenarios/stdlib-knot)'
task :fixture, [:dir, :scenario] do |_t, args|
  dir = args[:dir]
  abort 'usage: rake fixture[DIR] or rake fixture[DIR,SCENARIO_DIR]' if dir.nil? || dir.strip.empty?

  require_relative '../spec/support/fixture_repo'
  scenario = args[:scenario] ? File.expand_path(args[:scenario]) : Pupgrade::FixtureRepo::SCENARIO
  result   = Pupgrade::ScenarioBuilder.new(scenario).build(dir)
  puts "fixture control repo: #{result.dir}"
  puts "  scenario:            #{scenario}"
  puts "  module remotes:      #{result.remotes_dir}"
  result.proposals.each_value { |path| puts "  proposal:            #{path}" }
  puts "  config:              #{result.config}" if File.file?(result.config)
  config = File.file?(result.config) ? " -c #{result.config}" : ''
  propose = result.proposed ? " --propose #{result.proposed}" : ''
  puts "try: bundle exec pupgrade check -d #{result.dir}#{config}#{propose}"
end
