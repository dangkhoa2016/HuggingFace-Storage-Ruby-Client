# frozen_string_literal: true

require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
RSpec::Core::RakeTask.new(:benchmark) do |t|
  t.rspec_opts = "--tag benchmark"
end

namespace :ext do
  desc "Compile native Gearhash extension"
  task :compile do
    dir = File.expand_path("ext/gearhash", __dir__)
    so_dest = File.expand_path("src/hugging_face_storage/gearhash.so", __dir__)
    if File.exist?(so_dest)
      puts "gearhash.so already exists, skipping compile"
    else
      sh "cd #{dir} && ruby extconf.rb && make"
      cp "#{dir}/gearhash.so", so_dest
      puts "Compiled gearhash.so → #{so_dest}"
    end
  end

  desc "Force recompile native Gearhash extension"
  task :recompile do
    dir = File.expand_path("ext/gearhash", __dir__)
    so_dest = File.expand_path("src/hugging_face_storage/gearhash.so", __dir__)
    rm_f so_dest
    sh "cd #{dir} && ruby extconf.rb && make"
    cp "#{dir}/gearhash.so", so_dest
    puts "Recompiled gearhash.so → #{so_dest}"
  end
end

namespace :benchmark do
  desc "Run upload pipeline benchmarks (CDC, batch Blake3, shard building)"
  task upload: "ext:compile" do
    ruby "benchmark/upload.rb"
  end

  desc "Run download pipeline benchmarks (xorb extraction, file reassembly, stream write)"
  task download: "ext:compile" do
    ruby "benchmark/download.rb"
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
