# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.1
FROM ghcr.io/rails/devcontainer/images/ruby:$RUBY_VERSION

USER root

# Install system dependencies
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential \
      curl \
      sqlite3 libsqlite3-dev \
      nodejs npm && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Switch to non-root user
USER vscode
