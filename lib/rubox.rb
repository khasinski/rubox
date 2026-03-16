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
end
