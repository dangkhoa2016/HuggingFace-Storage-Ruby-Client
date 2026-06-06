# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::LocalFileCollector do
  subject(:collector) { described_class }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      FileUtils.mkdir_p(File.join(dir, "sub"))
      File.write(File.join(dir, "a.txt"), "a")
      File.write(File.join(dir, "b.rb"), "b")
      File.write(File.join(dir, "sub", "c.txt"), "c")
      File.write(File.join(dir, "sub", "d.rb"), "d")
      example.run
    end
  end

  it "collects all files recursively" do
    files = collector.collect(@tmpdir, nil)
    expect(files.size).to eq(4)
    expect(files).to all(satisfy { |f| File.file?(f) })
  end

  it "returns sorted results" do
    files = collector.collect(@tmpdir, nil)
    expect(files).to eq(files.sort)
  end

  it "excludes files matching patterns" do
    files = collector.collect(@tmpdir, ["*.rb"])
    expect(files).to all(end_with(".txt"))
    expect(files.size).to eq(2)
  end

  it "excludes using multiple patterns" do
    files = collector.collect(@tmpdir, ["*.rb", "sub/*"])
    expect(files).to eq([File.join(@tmpdir, "a.txt")])
  end

  it "handles empty directory" do
    Dir.mktmpdir do |empty_dir|
      files = collector.collect(empty_dir, nil)
      expect(files).to eq([])
    end
  end
end
