require "yaml"

module Rubox
  class Detector
    CONFIG_FILE = ".rubox.yml"

    attr_reader :dir

    def initialize(dir = Dir.pwd)
      @dir = dir
      @config = load_config
    end

    def config
      @config
    end

    def ruby_version
      @config["ruby_version"] || from_ruby_version_file || from_gemfile || current_ruby_version
    end

    def gemfile_path
      if @config["gemfile"]
        path = File.expand_path(@config["gemfile"], dir)
        return path if File.exist?(path)
      end

      %w[Gemfile gems.rb].each do |name|
        path = File.join(dir, name)
        return path if File.exist?(path)
      end
      nil
    end

    def entry_name
      return @config["entry"] if @config["entry"]

      gemspec = Dir.glob(File.join(dir, "*.gemspec")).first
      if gemspec
        content = File.read(gemspec)
        if content =~ /spec\.executables\s*=.*?["']([^"']+)["']/
          return $1
        end
      end

      File.basename(dir)
    end

    def target
      @config["target"]
    end

    def prune
      @config["prune"]
    end

    def keep_gems
      gems = @config["keep_gems"]
      gems.is_a?(Array) ? gems.join(",") : gems
    end

    def gem_name
      @config["gem"]
    end

    def has_config?
      File.exist?(File.join(dir, CONFIG_FILE))
    end

    private

    def load_config
      path = File.join(dir, CONFIG_FILE)
      return {} unless File.exist?(path)

      config = YAML.safe_load_file(path, permitted_classes: [Symbol]) || {}
      config.transform_keys(&:to_s)
    rescue => e
      $stderr.puts "rubox: warning: failed to parse #{CONFIG_FILE}: #{e.message}"
      {}
    end

    def from_ruby_version_file
      path = File.join(dir, ".ruby-version")
      return nil unless File.exist?(path)

      version = File.read(path).strip.sub(/^ruby-/, "")
      version.match?(/^\d+\.\d+\.\d+$/) ? version : nil
    end

    def from_gemfile
      path = gemfile_path
      return nil unless path

      content = File.read(path)
      if content =~ /^\s*ruby\s+["'](\d+\.\d+\.\d+)["']/
        $1
      end
    end

    def current_ruby_version
      RUBY_VERSION
    end
  end
end
