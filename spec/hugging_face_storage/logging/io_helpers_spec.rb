# frozen_string_literal: true

require "spec_helper"

RSpec.describe HuggingFaceStorage::StripIO do
  it "strips ANSI escape codes on write" do
    io = StringIO.new
    strip = described_class.new(io)
    strip.write("\e[31mhello\e[0m")
    expect(io.string).to eq("hello")
  end

  it "passes through plain text unchanged" do
    io = StringIO.new
    strip = described_class.new(io)
    strip.write("hello world")
    expect(io.string).to eq("hello world")
  end

  it "delegates other methods to the wrapped IO" do
    io = StringIO.new
    strip = described_class.new(io)
    expect(strip.tell).to eq(0)
  end
end

RSpec.describe HuggingFaceStorage::TeeIO do
  it "writes to all IO objects" do
    io1 = StringIO.new
    io2 = StringIO.new
    tee = described_class.new(io1, io2)
    tee.write("hello")
    expect(io1.string).to eq("hello")
    expect(io2.string).to eq("hello")
  end

  it "returns the first IO as the delegate" do
    io1 = StringIO.new
    io2 = StringIO.new
    tee = described_class.new(io1, io2)

    expect(tee.tell).to eq(0)
    tee.write("data")
    expect(io1.string).to eq("data")
    expect(io2.string).to eq("data")
  end

  it "does not close $stdout or $stderr" do
    non_special = StringIO.new
    tee = described_class.new($stdout, non_special)
    tee.close
    expect(non_special).to be_closed
  end

  it "closes non-special streams" do
    io1 = StringIO.new
    io2 = StringIO.new
    tee = described_class.new(io1, io2)
    tee.close
    expect(io1).to be_closed
    expect(io2).to be_closed
  end
end
