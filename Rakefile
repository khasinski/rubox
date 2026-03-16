desc "Run test suite"
task :test do
  sh "./test/test-packaging.sh"
end

desc "Build herb as a quick smoke test"
task :herb do
  ruby "-Ilib", "exe/rubox", "pack", "-y", "--gem", "herb"
end

desc "Clean build artifacts"
task :clean do
  rm_rf "build"
end

task default: :test
