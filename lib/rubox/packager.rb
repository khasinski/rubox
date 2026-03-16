module Rubox
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
      Rubox.validate_data_dir!
      script = File.join(Rubox.data_dir, "scripts", "package.sh")
      stub = stub_path
      ensure_write_footer!

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
        "RUBOX_DATA_DIR" => Rubox.data_dir,
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

    # Find a pre-built stub for the target, or compile one from source.
    def stub_path
      prebuilt = File.join(Rubox.data_dir, "stubs", "stub-#{@target}")
      return prebuilt if File.exist?(prebuilt)

      # No pre-built stub -- compile from source
      stub = File.join("build", "stub-#{@target}")
      unless File.exist?(stub)
        Dir.mkdir("build") unless Dir.exist?("build")
        src = File.join(Rubox.data_dir, "ext", "stub.c")

        if Platform.cross_build?(@target)
          puts "Cross-compiling stub for #{@target} via Docker..."
          docker_platform = @target.start_with?("x86_64") ? "linux/amd64" : "linux/arm64"
          system(
            "docker", "run", "--rm", "--platform", docker_platform,
            "-v", "#{Dir.pwd}:/src", "-w", "/src",
            "alpine:3.21",
            "sh", "-c",
            "apk add --no-cache gcc musl-dev >/dev/null 2>&1 && " \
            "cc -O2 -Wall -Wextra -static -o #{stub} #{src}",
            exception: true
          )
        else
          system("cc", "-O2", "-Wall", "-Wextra", "-o", stub, src, exception: true)
        end
      end
      stub
    end

    def ensure_write_footer!
      prebuilt = File.join(Rubox.data_dir, "stubs", "write-footer-#{@target}")
      if File.exist?(prebuilt)
        # Symlink pre-built into build/ so package.sh can find it
        Dir.mkdir("build") unless Dir.exist?("build")
        wf = File.join("build", "write-footer")
        FileUtils.cp(prebuilt, wf) unless File.exist?(wf)
        return
      end

      wf = File.join("build", "write-footer")
      return if File.exist?(wf)

      Dir.mkdir("build") unless Dir.exist?("build")
      src = File.join(Rubox.data_dir, "ext", "write-footer.c")
      system("cc", "-O2", "-Wall", "-Wextra", "-o", wf, src, exception: true)
    end
  end
end
