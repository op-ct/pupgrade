require_relative 'scenario_builder'

module Pupgrade
  # The control repo pupgrade's specs run against: the `stdlib-knot`
  # scenario under spec/fixtures/scenarios/, built by {ScenarioBuilder}.
  # Bare git remotes with one commit and tag per release of each module, a
  # deployed environment with every module cloned at the tag its Puppetfile
  # declares, two Forge-style modules on disk, a pupgrade.yaml, and a
  # Puppetfile.proposed that bumps stdlib a major version and a few modules
  # with it. The current state has every conflict kind; the proposal
  # introduces many more and resolves a few.
  #
  # Commits carry fixed authors and dates, so two builds give the same shas.
  module FixtureRepo
    SCENARIO = File.expand_path('../fixtures/scenarios/stdlib-knot', __dir__)

    Mod     = ScenarioBuilder::Mod
    Release = ScenarioBuilder::Release
    Result  = ScenarioBuilder::Result

    # The scenario's modules, in build order.
    CATALOGUE = ScenarioBuilder.new(SCENARIO).modules.freeze

    # @param dir [String] an empty or absent directory
    # @return [ScenarioBuilder::Result]
    def self.build(dir)
      ScenarioBuilder.new(SCENARIO).build(dir)
    end
  end
end
