ARG RUBY_VERSION=3.3

FROM mcr.microsoft.com/devcontainers/ruby:${RUBY_VERSION}

RUN apt-get update -qq && apt-get install -y \
  build-essential \
  pkg-config \
  cmake \
  && rm -rf /var/lib/apt/lists/*

ENV APP_HOME=/workspaces/huggingface
WORKDIR $APP_HOME
