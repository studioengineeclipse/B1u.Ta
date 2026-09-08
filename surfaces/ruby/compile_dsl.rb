# frozen_string_literal: true

# Compiles a scene written in the authoring DSL into a canonical B1_VIDEO_IR document.
#
#   ruby surfaces/ruby/compile_dsl.rb <scene.b1.rb> [output.json]
#
# With no output path the IR goes to stdout, so it pipes straight into `b1 plan` or any of the
# fourteen conform entrypoints.

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require 'b1/canon'
require 'b1/dsl'

path = ARGV[0]
if path.nil?
  warn 'usage: compile_dsl.rb <scene.b1.rb> [output.json]'
  exit 2
end

begin
  scene = eval(File.read(path), TOPLEVEL_BINDING, path) # rubocop:disable Security/Eval
rescue B1::DSLError => e
  warn "authoring error in #{path}: #{e.message}"
  exit 1
end

unless scene.is_a?(B1::Scene)
  warn "#{path} did not produce a scene; the file should end with a B1.scene block"
  exit 1
end

begin
  text = scene.to_json_text
rescue B1::DSLError => e
  warn "authoring error in #{path}: #{e.message}"
  exit 1
end

if ARGV[1]
  File.write(ARGV[1], "#{text}\n")
  warn "wrote #{ARGV[1]}  #{scene.digest}"
else
  puts text
end
