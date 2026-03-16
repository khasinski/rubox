require_relative "lib/rubox/version"

Gem::Specification.new do |spec|
  spec.name = "rubox"
  spec.version = Rubox::VERSION
  spec.authors = ["Chris Hasinski"]
  spec.email = ["krzysztof.hasinski@gmail.com"]

  spec.summary = "Package Ruby apps into single portable binaries"
  spec.description = "Build self-contained, single-file executables from Ruby gems " \
                     "or Gemfile-based apps. Works on macOS and Linux (any distro)."
  spec.homepage = "https://github.com/khasinski/rubox"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.0.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "exe/*",
    "data/**/*",
    "LICENSE",
  ]

  spec.bindir = "exe"
  spec.executables = ["rubox"]
  spec.require_paths = ["lib"]

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/commits/main"
end
