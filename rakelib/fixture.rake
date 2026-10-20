desc 'Build the fixture control repo (git module remotes, deployed clones, Puppetfile.proposed) into DIR'
task :fixture, [:dir] do |_t, args|
  dir = args[:dir]
  abort 'usage: rake fixture[DIR]' if dir.nil? || dir.strip.empty?

  require_relative '../spec/support/fixture_repo'
  result = Pupgrade::FixtureRepo.build(dir)
  puts "fixture control repo: #{result.dir}"
  puts "  module remotes:     #{result.remotes_dir}"
  puts "  proposed Puppetfile: #{result.proposed}"
  puts "  config:              #{result.config}"
  puts "try: bundle exec pupgrade modules resolve -d #{result.dir} -c #{result.config} --propose #{result.proposed}"
end
