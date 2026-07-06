# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::NullLogger do
  subject(:logger) { described_class.new }

  it "responds to debug" do
    expect { logger.debug("msg") }.not_to raise_error
  end

  it "responds to info" do
    expect { logger.info("msg") }.not_to raise_error
  end

  it "responds to warn" do
    expect { logger.warn("msg") }.not_to raise_error
  end

  it "responds to error" do
    expect { logger.error("msg") }.not_to raise_error
  end

  it "responds to fatal" do
    expect { logger.fatal("msg") }.not_to raise_error
  end

  it "accepts a block instead of message" do
    expect { logger.debug { "msg" } }.not_to raise_error
  end

  it "returns :info from level" do
    expect(logger.level).to eq(:info)
  end

  it "accepts level assignment" do
    expect { logger.level = :debug }.not_to raise_error
  end

  it "returns :default from format" do
    expect(logger.format).to eq(:default)
  end

  it "accepts format assignment" do
    expect { logger.format = :json }.not_to raise_error
  end

  it "responds to close" do
    expect { logger.close }.not_to raise_error
  end
end
