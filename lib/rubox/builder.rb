require "open3"

module Rubox
  class Builder
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
