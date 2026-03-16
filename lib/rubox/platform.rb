module Rubox
  module Platform
    def self.host_arch
      arch = RbConfig::CONFIG["host_cpu"] || `uname -m`.strip
      case arch
      when /arm64|aarch64/ then "aarch64"
      when /x86_64|amd64/  then "x86_64"
      else arch
      end
    end

    def self.host_os
      case RbConfig::CONFIG["host_os"]
      when /darwin/ then "darwin"
      when /linux/  then "linux"
      else `uname -s`.strip.downcase
      end
    end

    def self.host_target
      "#{host_arch}-#{host_os}"
    end

    def self.valid_targets
      %w[aarch64-darwin x86_64-darwin aarch64-linux x86_64-linux]
    end

    def self.valid_target?(target)
      valid_targets.include?(target)
    end

    def self.cross_build?(target)
      target != host_target
    end

    def self.linux_target?(target)
      target.end_with?("-linux")
    end
  end
end
