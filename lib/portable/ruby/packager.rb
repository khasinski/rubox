module Portable
  module Ruby
    class Packager
      def initialize(ruby_dir:, output:, target:, gem_name: nil, gemfile: nil,
                     entry: nil, prune: "default", keep_gems: nil)
        @ruby_dir = ruby_dir
        @output = output
        @target = target
        @gem_name = gem_name
        @gemfile = gemfile
        @entry = entry || gem_name
        @prune = prune
        @keep_gems = keep_gems
      end

      def package!
        script = File.join(Portable::Ruby.data_dir, "scripts", "package.sh")
        stub = stub_path

        args = [
          script,
          "--ruby-dir", @ruby_dir,
          "--stub", stub,
          "--output", @output,
          "--prune", @prune,
        ]

        if @gem_name
          args += ["--gem", @gem_name]
          args += ["--entry", @entry] if @entry
        elsif @gemfile
          args += ["--gemfile", @gemfile]
          args += ["--entry", @entry] if @entry
        end

        args += ["--keep-gems", @keep_gems] if @keep_gems

        env = {
          "PORTABLE_RUBY_DATA_DIR" => Portable::Ruby.data_dir,
        }

        system(env, *args, exception: true)
      end

      def install_gem!(gem_name)
        ruby_bin = File.join(@ruby_dir, "bin", "ruby")

        if File.exist?(ruby_bin) && system(ruby_bin, "--version", out: File::NULL, err: File::NULL)
          # Native platform -- run gem install directly
          gem_cmd = File.join(@ruby_dir, "bin", "gem")
          system(gem_cmd, "install", gem_name, "--no-document", exception: true)
        else
          # Cross-platform -- use Docker
          puts "Installing #{gem_name} via Docker (cross-platform)..."
          system(
            "docker", "run", "--rm",
            "-v", "#{File.expand_path(@ruby_dir)}:/opt/ruby",
            "alpine:3.21",
            "sh", "-c",
            "apk add --no-cache build-base libgcc >/dev/null 2>&1 && /opt/ruby/bin/gem install #{gem_name} --no-document",
            exception: true
          )
        end
      end

      private

      def stub_path
        if Platform.linux_target?(@target) && !Platform.linux_target?(Platform.host_target)
          build_linux_stub
        else
          build_host_stub
        end
      end

      def build_host_stub
        stub = File.join("build", "stub")
        unless File.exist?(stub)
          compile_stub("stub.c", stub)
        end
        stub
      end

      def build_linux_stub
        stub = File.join("build", "stub-linux")
        unless File.exist?(stub)
          puts "Cross-compiling stub for Linux via Docker..."
          system(
            "docker", "run", "--rm",
            "-v", "#{Dir.pwd}:/src", "-w", "/src",
            "alpine:3.21",
            "sh", "-c",
            "apk add --no-cache gcc musl-dev >/dev/null 2>&1 && " \
            "cc -O2 -Wall -Wextra -static -o build/stub-linux #{stub_source}",
            exception: true
          )
        end
        stub
      end

      def compile_stub(source, output)
        Dir.mkdir("build") unless Dir.exist?("build")
        system("cc", "-O2", "-Wall", "-Wextra", "-o", output, stub_source, exception: true)
      end

      def stub_source
        File.join(Portable::Ruby.data_dir, "ext", "stub.c")
      end
    end
  end
end
