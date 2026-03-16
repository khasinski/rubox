require "open3"

module Portable
  module Ruby
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
        script = File.join(Portable::Ruby.data_dir, "scripts", "build-ruby.sh")

        env = {
          "PORTABLE_RUBY_DATA_DIR" => Portable::Ruby.data_dir,
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
end
