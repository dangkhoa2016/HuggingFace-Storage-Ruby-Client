# frozen_string_literal: true

require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
RSpec::Core::RakeTask.new(:benchmark) do |t|
  t.rspec_opts = "--tag benchmark"
end

namespace :benchmark do
  desc "Run upload pipeline benchmarks (CDC, batch Blake3, shard building)"
  task :upload do
    ruby "bench/bench_upload.rb"
  end

  desc "Run download pipeline benchmarks (xorb extraction, file reassembly, stream write)"
  task :download do
    ruby "bench/bench_download.rb"
  end

  desc "Run all benchmarks"
  task all: %i[upload download]
end

RuboCop::RakeTask.new(:lint)

begin
  gem "rbs"
  desc "Validate RBS type signatures"
  task :type_check do
    sh "bundle exec rbs validate"
  end
rescue LoadError
  desc "Validate RBS type signatures (disabled without rbs gem)"
  task :type_check do
    warn "rbs gem not available — skipping type check"
  end
end

begin
  gem "steep"
  desc "Static type check with Steep"
  task :steep do
    sh "bundle exec steep check --severity-level=error"
  end
rescue LoadError
  desc "Static type check with Steep (disabled without steep gem)"
  task :steep do
    warn "steep gem not available — skipping type check"
  end
end

task default: %i[lint steep spec]

begin
  require "yard"
  YARD::Rake::YardocTask.new do |t|
    t.files   = ["src/**/*.rb"]
    t.options = ["--output-dir", "docs/api"]
  end
rescue LoadError
  # yard not available — skip doc tasks in CI
end
