module Portable
  module Ruby
    class Detector
      attr_reader :dir

      def initialize(dir = Dir.pwd)
        @dir = dir
      end

      def ruby_version
        from_ruby_version_file || from_gemfile || current_ruby_version
      end

      def gemfile_path
        %w[Gemfile gems.rb].each do |name|
          path = File.join(dir, name)
          return path if File.exist?(path)
        end
        nil
      end

      def entry_name
        # Try to detect from gemspec or Gemfile binstubs
        gemspec = Dir.glob(File.join(dir, "*.gemspec")).first
        if gemspec
          content = File.read(gemspec)
          if content =~ /spec\.executables\s*=.*?["']([^"']+)["']/
            return $1
          end
        end

        # Fall back to directory name
        File.basename(dir)
      end

      private

      def from_ruby_version_file
        path = File.join(dir, ".ruby-version")
        return nil unless File.exist?(path)

        version = File.read(path).strip.sub(/^ruby-/, "")
        # Must look like a version number
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
end
