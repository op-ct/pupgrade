source ENV['GEM_SOURCE'] || 'https://rubygems.org'

gemspec

# driftless is not published yet; develop against the sibling checkout.
gem 'driftless', path: '../driftless'

gem 'rake'

# PSON for modules written before Puppet 8; loaded only by `--pson`.
gem 'puppet-pson', require: false

group :test do
  gem 'rspec',     '~> 3.12'
  gem 'rspec-its', '~> 2.0'
end

group :development do
  gem 'pry'
  gem 'rubocop'
  gem 'rubocop-performance'
  gem 'rubocop-rake'
  gem 'rubocop-rspec'
end
