#!/usr/bin/env ruby

require "fileutils"
require "tmpdir"

PATCHES = File.dirname(File.expand_path(__FILE__))
SVD = ARGV[0] || "svd"

# Applied in order, so devices needing two corrections get both.
CORRECTIONS = {
  "tim_cnt.yaml" => %w[
    stm32f722 stm32f723 stm32f730 stm32f732 stm32f733 stm32f745
    stm32f746 stm32f750 stm32f756 stm32f765 stm32f767 stm32f769
    stm32f777 stm32f778 stm32f779 stm32g431 stm32g441 stm32g471
    stm32g473 stm32g474 stm32g483 stm32g484 stm32g491 stm32g4a1
    stm32h503 stm32h562 stm32h563 stm32h573 stm32h7r stm32h7s
    stm32u535 stm32u545 stm32u575 stm32u585 stm32u595 stm32u599
    stm32u5a5 stm32u5a9
  ],

  "tim_cnt_h5.yaml" => %w[stm32h523 stm32h533],
  "tim_cnt_wb55.yaml" => %w[stm32wb55],
  "flash_eccr.yaml" => %w[stm32l4p5 stm32l4r9],
  "otg_gadpctl.yaml" => %w[stm32l4p5 stm32l4r5 stm32l4r9],
  "cryp_k2lr.yaml" => %w[stm32h730 stm32h733 stm32h735],
}.freeze

def apply(fragment, device)
  target = File.join(SVD, "#{device}.svd.patched")
  abort("error: #{target} not found; run 'make patch' first") unless File.file?(target)

  Dir.mktmpdir do |work|
    scratch = File.join(work, "#{device}.svd")
    manifest = File.join(work, "patch.yaml")

    FileUtils.cp(target, scratch)
    File.write(
      manifest,
      "_svd: #{scratch}\n_include:\n  - #{File.join(PATCHES, fragment)}\n",
    )

    system("svdtools", "patch", manifest) ||
      abort("error: svdtools failed on #{device} with #{fragment}")

    patched = "#{scratch}.patched"
    abort("error: svdtools wrote no output for #{device}") unless File.file?(patched)

    FileUtils.mv(patched, target)
  end

  puts "  #{device} <- #{fragment}"
end

puts "Applying swift-mmio compatibility corrections:"

CORRECTIONS.each do |fragment, devices|
  devices.each { |device| apply(fragment, device) }
end

puts "Done."
