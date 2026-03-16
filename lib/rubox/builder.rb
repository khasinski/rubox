require "open3"
require "net/http"
require "uri"
require "fileutils"

module Rubox
  class Builder
    # Pre-built Ruby binaries are hosted at this base URL.
    # Falls back to building from source if download fails.
    DOWNLOAD_BASE = "https://github.com/khasinski/rubox/releases/download"

    attr_reader :ruby_version, :target, :output_dir

    def initialize(ruby_version:, target:, output_dir: nil)
      @ruby_version = ruby_version
      @target = target
      @output_dir = output_dir || "build/ruby-#{ruby_version}-#{target}"
    end

    def built?
      File.exist?(File.join(output_dir, "bin", "ruby"))
    end

    def build!
      return if built?

      if try_download
        puts "==> Using pre-built Ruby #{ruby_version} for #{target}"
        return
      end

      puts "==> No pre-built binary available, building from source..."
      build_from_source!
    end

    private

    def try_download
      url = "#{DOWNLOAD_BASE}/ruby-#{ruby_version}/ruby-#{ruby_version}-#{target}.tar.gz"
      tarball = "#{output_dir}.tar.gz"

      puts "==> Checking for pre-built Ruby #{ruby_version} for #{target}..."

      begin
        uri = URI(url)
        # Follow redirects (GitHub releases redirect to S3)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                   open_timeout: 5, read_timeout: 30) do |http|
          request = Net::HTTP::Head.new(uri)
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
          puts "    Not found (#{response.code})"
          return false
        end

        puts "    Downloading..."
        FileUtils.mkdir_p(File.dirname(tarball))

        # Stream download
        download_file(url, tarball)

        puts "    Extracting..."
        FileUtils.mkdir_p(output_dir)
        system("tar", "xzf", tarball, "-C", output_dir, exception: true)
        FileUtils.rm_f(tarball)

        if built?
          puts "    Ruby #{ruby_version} ready at #{output_dir}"
          return true
        else
          puts "    Download extracted but Ruby binary not found, falling back to source build"
          FileUtils.rm_rf(output_dir)
          return false
        end
      rescue StandardError => e
        puts "    Download failed (#{e.message}), will build from source"
        FileUtils.rm_f(tarball)
        return false
      end
    end

    def download_file(url, dest)
      uri = URI(url)
      max_redirects = 5

      max_redirects.times do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                        read_timeout: 120) do |http|
          request = Net::HTTP::Get.new(uri)
          http.request(request) do |response|
            case response
            when Net::HTTPRedirection
              uri = URI(response["location"])
              next
            when Net::HTTPSuccess
              File.open(dest, "wb") do |f|
                response.read_body { |chunk| f.write(chunk) }
              end
              return
            else
              raise "HTTP #{response.code}"
            end
          end
        end
      end

      raise "Too many redirects"
    end

    def build_from_source!
      Rubox.validate_data_dir!
      script = File.join(Rubox.data_dir, "scripts", "build-ruby.sh")

      env = {
        "RUBOX_DATA_DIR" => Rubox.data_dir,
      }

      cmd = [
        script,
        "--ruby-version", ruby_version,
        "--target", target,
        "--output", output_dir,
      ]

      system(env, *cmd, exception: true)
    end
  end
end
