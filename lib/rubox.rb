require "fileutils"
require "rubox/version"
require "rubox/platform"
require "rubox/detector"
require "rubox/builder"
require "rubox/packager"

module Rubox
  def self.data_dir
    @data_dir ||= File.expand_path("../data", __dir__)
  end

  REQUIRED_DATA_FILES = %w[
    scripts/build-ruby.sh
    scripts/package.sh
    scripts/_common.sh
    ext/stub.c
    ext/write-footer.c
    Dockerfile.ruby-build
    prune-list.conf
  ].freeze

  def self.validate_data_dir!
    missing = REQUIRED_DATA_FILES.select { |f| !File.exist?(File.join(data_dir, f)) }
    return if missing.empty?

    abort "rubox: data directory incomplete (#{data_dir}).\n" \
          "Missing: #{missing.join(', ')}\n" \
          "Reinstall the gem: gem install rubox"
  end
end
