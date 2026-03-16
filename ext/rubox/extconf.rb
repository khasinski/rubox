require "mkmf"

# We compile standalone executables (stub, write-footer), not a Ruby C extension.
# Generate a custom Makefile that builds them as binaries.

cc = RbConfig::CONFIG["CC"] || "cc"
src_dir = File.expand_path("../../data/ext", __dir__)
stub_src = File.join(src_dir, "stub.c")
footer_src = File.join(src_dir, "write-footer.c")

# The extension dir is where rubygems puts compiled artifacts
ext_dir = File.expand_path(".")

File.open("Makefile", "w") do |f|
  f.puts <<~MAKEFILE
    CC = #{cc}
    CFLAGS = -O2 -Wall -Wextra

    all: stub write-footer

    stub: #{stub_src}
    \t$(CC) $(CFLAGS) -o $@ $<

    write-footer: #{footer_src}
    \t$(CC) $(CFLAGS) -o $@ $<

    install: all
    \tmkdir -p $(DESTDIR)$(sitearchdir)
    \tcp stub write-footer $(DESTDIR)$(sitearchdir)/

    clean:
    \trm -f stub write-footer

    distclean: clean

    .PHONY: all install clean distclean
  MAKEFILE
end

puts "Makefile generated for rubox native tools"
