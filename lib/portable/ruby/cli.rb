require "optparse"
require "portable/ruby"

module Portable
  module Ruby
    class CLI
      def self.run(argv)
        new(argv).run
      end

      def initialize(argv)
        @argv = argv.dup
        @options = {
          target: Platform.host_target,
          prune: "default",
          yes: false,
        }
      end

      def run
        command = @argv.shift

        case command
        when "pack"
          parse_pack_options!
          cmd_pack
        when "build-ruby"
          parse_build_options!
          cmd_build_ruby
        when "clean"
          cmd_clean
        when "-h", "--help", "help", nil
          print_usage
        when "-v", "--version"
          puts "portable-ruby #{VERSION}"
        else
          $stderr.puts "Unknown command: #{command}"
          $stderr.puts "Run: portable-ruby --help"
          exit 1
        end
      end

      private

      def parse_pack_options!
        OptionParser.new do |opts|
          opts.banner = "Usage: portable-ruby pack [options]"
          opts.on("--gem NAME", "Package a rubygems gem") { |v| @options[:gem] = v }
          opts.on("--gemfile PATH", "Package a Gemfile-based app") { |v| @options[:gemfile] = v }
          opts.on("--entry BIN", "Entry point binary name") { |v| @options[:entry] = v }
          opts.on("--target TARGET", "Target platform") { |v| @options[:target] = v }
          opts.on("--output PATH", "Output binary path") { |v| @options[:output] = v }
          opts.on("--prune LEVEL", "Prune level: none, default") { |v| @options[:prune] = v }
          opts.on("--keep-gems LIST", "Comma-separated gems to keep") { |v| @options[:keep_gems] = v }
          opts.on("-y", "--yes", "Skip confirmation prompts") { @options[:yes] = true }
        end.parse!(@argv)
      end

      def parse_build_options!
        OptionParser.new do |opts|
          opts.banner = "Usage: portable-ruby build-ruby [options]"
          opts.on("--target TARGET", "Target platform") { |v| @options[:target] = v }
          opts.on("--ruby-version VER", "Ruby version") { |v| @options[:ruby_version] = v }
          opts.on("-y", "--yes", "Skip confirmation prompts") { @options[:yes] = true }
        end.parse!(@argv)
      end

      def cmd_pack
        detector = Detector.new
        target = @options[:target]

        # Auto-detect mode if neither --gem nor --gemfile specified
        gem_name = @options[:gem]
        gemfile = @options[:gemfile]

        if gem_name.nil? && gemfile.nil?
          gemfile = detector.gemfile_path
          if gemfile
            puts "Detected Gemfile: #{gemfile}"
          else
            $stderr.puts "ERROR: No --gem or --gemfile specified and no Gemfile found in #{Dir.pwd}"
            exit 1
          end
        end

        # Detect Ruby version
        ruby_version = @options[:ruby_version] || detector.ruby_version
        entry = @options[:entry] || gem_name || detector.entry_name

        # Output path
        output = @options[:output] || begin
          name = entry || gem_name || File.basename(Dir.pwd)
          suffix = (target != Platform.host_target) ? "-#{target}" : ""
          "build/#{name}#{suffix}"
        end

        ruby_dir = "build/ruby-#{ruby_version}-#{target}"

        # Build Ruby if needed
        builder = Builder.new(ruby_version: ruby_version, target: target, output_dir: ruby_dir)

        unless builder.built?
          puts ""
          puts "portable-ruby needs to fetch and compile a static Ruby #{ruby_version} for #{target}."
          puts "This is a one-time operation (cached for future builds)."
          puts ""

          unless @options[:yes]
            print "Continue? [y/N] "
            answer = $stdin.gets&.strip&.downcase
            unless answer == "y" || answer == "yes"
              puts "Aborted."
              exit 0
            end
          end

          builder.build!
        end

        # Install gem if needed
        packager = Packager.new(
          ruby_dir: ruby_dir,
          output: output,
          target: target,
          gem_name: gem_name,
          gemfile: gemfile,
          entry: entry,
          prune: @options[:prune],
          keep_gems: @options[:keep_gems],
        )

        if gem_name
          gem_found = Dir.glob(File.join(ruby_dir, "lib/ruby/gems/*/gems/#{gem_name}-*")).any?
          unless gem_found
            packager.install_gem!(gem_name)
          end
        end

        packager.package!

        puts ""
        puts "Binary ready: #{output}"
      end

      def cmd_build_ruby
        detector = Detector.new
        ruby_version = @options[:ruby_version] || detector.ruby_version
        target = @options[:target]

        builder = Builder.new(ruby_version: ruby_version, target: target)

        if builder.built?
          puts "Ruby #{ruby_version} for #{target} already built at #{builder.output_dir}"
          return
        end

        puts ""
        puts "portable-ruby needs to fetch and compile a static Ruby #{ruby_version} for #{target}."
        puts "This is a one-time operation."
        puts ""

        unless @options[:yes]
          print "Continue? [y/N] "
          answer = $stdin.gets&.strip&.downcase
          unless answer == "y" || answer == "yes"
            puts "Aborted."
            exit 0
          end
        end

        builder.build!
      end

      def cmd_clean
        puts "Cleaning build artifacts..."
        FileUtils.rm_rf("build")
        puts "Done."
      end

      def print_usage
        puts <<~USAGE
          portable-ruby v#{VERSION} - Package Ruby apps into single portable binaries.

          Usage:
            portable-ruby pack [options]       Package a gem or app into a single binary
            portable-ruby build-ruby [options]  Build the static Ruby interpreter
            portable-ruby clean                 Remove build artifacts
            portable-ruby --version             Show version

          Pack options:
            --gem NAME        Package a rubygems gem
            --gemfile PATH    Package a Gemfile-based app (auto-detected if present)
            --entry BIN       Entry point binary name (defaults to gem name)
            --target TARGET   Target platform (default: #{Platform.host_target})
            --output PATH     Output binary path
            --prune LEVEL     Prune level: none, default (default: default)
            --keep-gems LIST  Comma-separated gems to keep despite prune list
            -y, --yes         Skip confirmation prompts

          Targets:
            aarch64-darwin    macOS Apple Silicon
            x86_64-darwin     macOS Intel
            aarch64-linux     Linux ARM64
            x86_64-linux      Linux x86_64

          Examples:
            portable-ruby pack --gem herb
            portable-ruby pack                      # auto-detects Gemfile
            portable-ruby pack -y --target aarch64-linux
        USAGE
      end
    end
  end
end
