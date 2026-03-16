# portable-ruby

Package any Ruby app into a single portable binary. Give it a gem name or a Gemfile and get one file you can copy to any machine.

Works on macOS (Intel + Apple Silicon) and Linux (any distro, any architecture).

## Quick start

```
gem install portable-ruby
```

Package a gem:

```
portable-ruby pack --gem herb
./build/herb --version
```

Package your app (auto-detects Gemfile in current directory):

```
cd my-app
portable-ruby pack
./build/my-app
```

## How it works

1. Downloads and compiles a static Ruby interpreter for your target platform
2. Installs your gem (or bundles your Gemfile) into that Ruby
3. Strips unused stdlib gems to reduce size
4. Compresses everything into a gzip payload
5. Prepends a tiny C stub that extracts and runs the payload

The result is a single file that contains Ruby + your app + all dependencies. On first run it extracts to a cache directory (~0.5s). Subsequent runs hit the cache and start instantly.

On Linux, the binary bundles its own musl libc and dynamic linker, so it runs on any distro (Ubuntu, Debian, Alpine, Fedora, RHEL, etc.) without any dependencies.

On macOS, all third-party libraries (OpenSSL, zlib, libyaml) are statically linked. Only system frameworks are dynamic (always present on any Mac).

## Usage

```
portable-ruby pack [options]
```

| Flag | Description |
|------|-------------|
| `--gem NAME` | Package a gem from rubygems.org |
| `--gemfile PATH` | Package a Gemfile-based app |
| `--entry BIN` | Entry point binary name (defaults to gem name) |
| `--target TARGET` | Target platform (default: current host) |
| `--output PATH` | Output path (default: `build/<name>`) |
| `-y, --yes` | Skip the confirmation prompt |
| `--prune LEVEL` | `none` or `default` (strips unused stdlib) |
| `--keep-gems LIST` | Comma-separated gems to keep despite pruning |

### Targets

| Target | Platform |
|--------|----------|
| `aarch64-darwin` | macOS Apple Silicon |
| `x86_64-darwin` | macOS Intel |
| `aarch64-linux` | Linux ARM64 |
| `x86_64-linux` | Linux x86_64 |

### Other commands

```
portable-ruby build-ruby              # just build the Ruby interpreter
portable-ruby clean                   # remove build artifacts
portable-ruby --version
```

## Examples

### Package a gem

```
portable-ruby pack --gem herb
./build/herb parse my_template.html.erb
```

### Package your Rails app's CLI

```
cd my-app
portable-ruby pack --entry bin/my_cli
scp build/my_cli production-server:
```

### Cross-compile for Linux from macOS

```
portable-ruby pack -y --gem herb --target aarch64-linux
# Copy build/herb-aarch64-linux to any Linux ARM64 machine
```

### Skip the confirmation prompt in CI

```
portable-ruby pack -y --gem my_tool
```

## First run

The first time you run `portable-ruby pack`, it needs to compile a static Ruby interpreter for your target. This takes 2-5 minutes and is cached for all future builds.

```
$ portable-ruby pack --gem herb

portable-ruby needs to fetch and compile a static Ruby 4.0.1 for aarch64-darwin.
This is a one-time operation (cached for future builds).

Continue? [y/N] y
==> Building Ruby 4.0.1 for aarch64-darwin...
```

Pass `-y` to skip the prompt.

## Runtime behavior

The packaged binary is self-extracting. On first execution it extracts the payload to a cache directory:

- **Linux (with exec-capable /dev/shm):** Extracts to RAM (`/dev/shm/portable-ruby/`)
- **Linux (noexec /dev/shm, e.g. Docker):** Falls back to `~/.cache/portable-ruby/`
- **macOS:** `~/.cache/portable-ruby/`

Subsequent runs find the cached extraction and start immediately (~0.1s overhead).

### Environment variables

| Variable | Description |
|----------|-------------|
| `PORTABLE_RUBY_CACHE` | Override cache directory |
| `PORTABLE_RUBY_NO_CACHE=1` | Extract to tmpdir and clean up on exit |
| `PORTABLE_RUBY_VERBOSE=1` | Print debug messages during extraction |

## Requirements

**Build machine** (where you run `portable-ruby pack`):

- Ruby 3.0+
- C compiler (Xcode CLI tools on macOS, gcc on Linux)
- Docker (for Linux cross-compilation from macOS)
- Homebrew (macOS, for static library dependencies)

**Target machine** (where the binary runs):

- Nothing. That's the point.

## How big are the binaries?

| App | Type | Gems | Binary size |
|-----|------|------|-------------|
| herb | Gem, C extension | 1 | 13 MB |
| doom | Gem, pure Ruby | 1 | 13 MB |
| sinatra app | Gemfile, web server | 5 | 14 MB |
| rails CLI | Gemfile, framework | 67 | 44 MB |

## Try the examples

Four example projects are included in `examples/`. Build them all:

```
./examples/build-all.sh
```

Or build individually:

```
# Gem mode
ruby -Ilib exe/portable-ruby pack -y --gem herb
ruby -Ilib exe/portable-ruby pack -y --gem doom --entry doom

# Gemfile mode
ruby -Ilib exe/portable-ruby pack -y --gemfile examples/sinatra-app/Gemfile --entry sinatra-app
ruby -Ilib exe/portable-ruby pack -y --gemfile examples/rails-cli/Gemfile --entry rails-cli
```

Test them:

```
./build/herb --version
./build/doom --version
./build/sinatra-app --check
./build/rails-cli --version
./build/rails-cli generate-key

# Parse some HTML+ERB
echo '<div><%= user.name %></div>' | ./build/herb parse -

# Start a web server
./build/sinatra-app &
curl http://localhost:4567/
kill %1
```

## Development

```
git clone https://github.com/khasinski/portable-ruby
cd portable-ruby
make test         # run the test suite (26 tests)
make herb         # build herb as a quick test case
```

## License

MIT
