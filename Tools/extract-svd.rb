#!/usr/bin/env ruby

#
# Build stm32-rs, copy svd/ out of a container, delete the container.
#   ./extract-svd.rb [commit] [outdir]
#
# A commit other than the Dockerfile default may need a different
# SVDTOOLS_VERSION too (see scripts/tool_install.sh in that commit).
#

require "fileutils"

commit = ARGV[0]
outdir = ARGV[1] || "svd"
context = File.dirname(File.expand_path(__FILE__))

def run(*command)
  system(*command) || abort("error: #{command.join(" ")} failed")
end

build = ["docker", "build"]
build.push("--build-arg", "STM32_RS_COMMIT=#{commit}") unless commit.to_s.empty?
build.push("-t", "stm32-rs-svd", context)
run(*build)

container = `docker create stm32-rs-svd`.strip
abort("error: docker create failed") if container.empty?

begin
  FileUtils.mkdir_p(outdir)
  run("docker", "cp", "#{container}:/build/svd/.", outdir)
ensure
  system("docker", "rm", "-f", container, out: File::NULL, err: File::NULL)
end

puts "Done."
