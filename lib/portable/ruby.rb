require "fileutils"
require "portable/ruby/version"
require "portable/ruby/platform"
require "portable/ruby/detector"
require "portable/ruby/builder"
require "portable/ruby/packager"

module Portable
  module Ruby
    def self.data_dir
      @data_dir ||= File.expand_path("../../data", __dir__)
    end
  end
end
