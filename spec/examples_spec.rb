# frozen_string_literal: true

require "spec_helper"
require "shellwords"

RSpec.describe "examples/usage.rb" do
  let(:examples_path) { File.expand_path("../examples/usage.rb", __dir__) }

  it "exists" do
    expect(File.exist?(examples_path)).to be true
  end

  it "has valid Ruby syntax" do
    output = `ruby -c #{examples_path.shellescape} 2>&1`
    expect(output).to include("Syntax OK")
  end
end

RSpec.describe "examples/usage.vi.rb" do
  let(:examples_path) { File.expand_path("../examples/usage.vi.rb", __dir__) }

  it "exists" do
    expect(File.exist?(examples_path)).to be true
  end

  it "has valid Ruby syntax" do
    output = `ruby -c #{examples_path.shellescape} 2>&1`
    expect(output).to include("Syntax OK")
  end
end

RSpec.describe "examples: require library" do
  it "loads hugging_face_storage without errors" do
    expect { require "hugging_face_storage" }.not_to raise_error
  end

  it "exposes HuggingFaceStorage module" do
    require "hugging_face_storage"
    expect(defined?(HuggingFaceStorage)).to be_truthy
  end

  it "exposes HuggingFaceStorage.new factory method" do
    require "hugging_face_storage"
    expect(HuggingFaceStorage).to respond_to(:new)
  end

  it "exposes all public classes" do
    require "hugging_face_storage"
    %i[
      Client FileManager DirectoryManager ApiClient XetUploader XetDownloader
      Authentication CancelToken BatchResult XetLazyFile
      Snapshot CopyPlanBuilder CopyPipeline
      FileInfo DirInfo Configuration
      HFLogger NullLogger
    ].each do |klass|
      expect(HuggingFaceStorage.const_defined?(klass)).to be(true), "Expected #{klass} to be defined"
    end
  end

  it "exposes all error classes" do
    require "hugging_face_storage"
    %i[
      Error AuthenticationError NotFoundError ConflictError
      ApiError CancelledError PartialFailureError
    ].each do |klass|
      expect(HuggingFaceStorage.const_defined?(klass)).to be(true), "Expected #{klass} to be defined"
    end
  end
end
