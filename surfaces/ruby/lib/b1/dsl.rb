# frozen_string_literal: true

# The scene-authoring DSL. Compiles to B1_VIDEO_IR (SPEC/10-b1-video-ir.md).
#
# Ruby owns this because the alternative — hand-writing several hundred lines of JSON per segment —
# is where continuity chains actually go wrong. A shot list is read and edited by people, and a
# surface that reads like a shot list catches mistakes that a wall of braces hides.
#
# Two rules are enforced here rather than downstream, because the authoring surface is where the
# author can still fix them cheaply:
#
#   * No floating point reaches the IR. Decimal quantities are written as strings and converted to
#     fixed point exactly (`frame_rate '23.976'` -> 23976 milli-fps). Passing a Float raises,
#     because 23.976 is not exactly representable and the digest would depend on how it rounded.
#   * A reference must state what requirement it serves. `because:` is a required keyword, so a
#     reference attached out of habit fails at authoring time rather than silently influencing the
#     result.

require_relative 'canon'

module B1
  class DSLError < StandardError; end

  # Converts a decimal written as a string into fixed point, exactly.
  #
  # Written as a string on purpose: `fixed(23.976, 1000)` would go through a Float and inherit its
  # rounding, which is the failure R1 exists to eliminate.
  def self.fixed(text, scale)
    raise DSLError, "write #{text} as a string, not a Float, so it converts exactly" if text.is_a?(Float)
    return text * scale if text.is_a?(Integer)

    s = text.to_s.strip
    raise DSLError, "#{s.inspect} is not a decimal number" unless s.match?(/\A-?\d+(\.\d+)?\z/)

    negative = s.start_with?('-')
    s = s.delete_prefix('-')
    whole, frac = s.split('.')
    digits = Math.log10(scale).round
    frac = (frac || '').ljust(digits, '0')
    raise DSLError, "#{text.inspect} has more precision than 1/#{scale}" if frac.length > digits

    value = (whole.to_i * scale) + frac.to_i
    negative ? -value : value
  end

  class Scene
    ROLES = %w[
      CHARACTER_IDENTITY FACE_IDENTITY BODY_DESIGN COSTUME ENVIRONMENT OBJECT STYLE COLOR
      COMPOSITION CAMERA MOTION ANIMATION_TIMING POSE ACTION VIDEO_CONTINUITY AUDIO
      OTHER_EXPLICIT_ROLE
    ].freeze

    MODES = %w[single_shot continuation extension variation repair].freeze

    def initialize(id)
      @id = id
      @ir = {
        'ir_version' => 'b1-video-ir/1',
        'characters' => [], 'identity_constraints' => [],
        'depth_layers' => [], 'foreground_elements' => [], 'midground_elements' => [],
        'background_elements' => [], 'props' => [], 'material_behavior' => [],
        'camera_motion' => [], 'subject_motion' => [], 'secondary_motion' => [],
        'interaction_graph' => [], 'physics_expectations' => [],
        'reference_bindings' => [], 'continuity_constraints' => [], 'negative_constraints' => [],
        'verification_requirements' => [],
        'origin' => { 'fields' => [] }
      }
      @origins = {}
    end

    # --- shot ---------------------------------------------------------------

    def objective(text, origin: 'U')
      @ir['objective'] = text
      note_origin('objective', origin)
    end

    def mode(name)
      name = name.to_s
      raise DSLError, "unknown scene mode #{name.inspect}; expected one of #{MODES.join(', ')}" unless MODES.include?(name)

      @ir['scene_mode'] = name
    end

    def seconds(value, origin: 'U')
      @ir['duration_ms'] = B1.fixed(value, 1000)
      note_origin('duration_ms', origin)
    end

    def resolution(width, height)
      @ir['target_resolution'] = { 'width_px' => width, 'height_px' => height }
    end

    def aspect(w, h)
      @ir['aspect_ratio'] = { 'w' => w, 'h' => h }
    end

    def frame_rate(value)
      @ir['target_frame_rate_mfps'] = B1.fixed(value, 1000)
    end

    # --- subjects -----------------------------------------------------------

    def character(id, name:, description:, identity_anchor: nil, costume: nil, body_design: nil)
      entry = { 'id' => id.to_s, 'name' => name, 'description' => description }
      entry['identity_anchor'] = identity_anchor if identity_anchor
      entry['costume'] = costume if costume
      entry['body_design'] = body_design if body_design
      @ir['characters'] << entry
    end

    def identity_constraint(character_id, constraint, tolerance_mu:)
      @ir['identity_constraints'] << {
        'character_id' => character_id.to_s, 'constraint' => constraint,
        'tolerance_mu' => tolerance_mu
      }
    end

    def prop(id, name:, description:)
      @ir['props'] << { 'id' => id.to_s, 'name' => name, 'description' => description }
    end

    def element(layer, id, name:, description:)
      key = case layer.to_sym
            when :foreground then 'foreground_elements'
            when :midground then 'midground_elements'
            when :background then 'background_elements'
            else raise DSLError, "unknown layer #{layer.inspect}"
            end
      @ir[key] << { 'id' => id.to_s, 'name' => name, 'description' => description }
    end

    # --- world --------------------------------------------------------------

    def environment(description, layout:, origin: 'M')
      @ir['environment'] = { 'description' => description, 'spatial_layout' => layout }
      note_origin('environment', origin)
    end

    def depth_layer(index, description)
      @ir['depth_layers'] << { 'index' => index, 'description' => description }
    end

    def lighting(description, key_direction: nil)
      @ir['lighting'] = { 'description' => description }
      @ir['lighting']['key_direction'] = key_direction if key_direction
    end

    def atmosphere(description)
      @ir['atmosphere'] = { 'description' => description }
    end

    def material(name, behaves:)
      @ir['material_behavior'] << { 'material' => name, 'behavior' => behaves }
    end

    def style(description)
      @ir['visual_style'] = { 'description' => description }
    end

    # --- camera -------------------------------------------------------------

    def camera(framing:, focal_mm:, position_mm: { 'x' => 0, 'y' => 1500, 'z' => 0 },
               orientation_mdeg: { 'pan' => 0, 'tilt' => 0, 'roll' => 0 })
      @ir['camera_state'] = {
        'position_mm' => stringify(position_mm),
        'orientation_mdeg' => stringify(orientation_mdeg),
        'focal_length_mm' => focal_mm,
        'framing' => framing
      }
    end

    def camera_move(kind, from:, to:, metres: nil, degrees: nil, framing_note: nil, origin: 'U')
      entry = {
        'kind' => kind.to_s,
        'start_ms' => B1.fixed(from, 1000),
        'end_ms' => B1.fixed(to, 1000)
      }
      entry['magnitude_mm'] = B1.fixed(metres, 1000) if metres
      entry['magnitude_mdeg'] = B1.fixed(degrees, 1000) if degrees
      entry['subject_framing_note'] = framing_note if framing_note
      @ir['camera_motion'] << entry
      note_origin('camera_motion', origin)
    end

    def lens(description, focus: nil)
      @ir['lens_behavior'] = { 'description' => description }
      @ir['lens_behavior']['focus_behavior'] = focus if focus
    end

    # --- motion -------------------------------------------------------------

    def motion(subject, action, from:, to:, starting_phase: nil, ending_phase: nil)
      entry = {
        'subject_id' => subject.to_s, 'action' => action,
        'start_ms' => B1.fixed(from, 1000), 'end_ms' => B1.fixed(to, 1000)
      }
      entry['phase_at_start'] = starting_phase if starting_phase
      entry['phase_at_end'] = ending_phase if ending_phase
      @ir['subject_motion'] << entry
    end

    def secondary_motion(element_id, behaves:)
      @ir['secondary_motion'] << { 'element_id' => element_id.to_s, 'behavior' => behaves }
    end

    def interaction(actor, relation, target, from:, to:)
      @ir['interaction_graph'] << {
        'actor_id' => actor.to_s, 'relation' => relation, 'target_id' => target.to_s,
        'start_ms' => B1.fixed(from, 1000), 'end_ms' => B1.fixed(to, 1000)
      }
    end

    def physics(subject, expectation)
      @ir['physics_expectations'] << { 'subject' => subject.to_s, 'expectation' => expectation }
    end

    def timing(description, beat: nil)
      @ir['animation_timing'] = { 'description' => description }
      @ir['animation_timing']['beat_ms'] = B1.fixed(beat, 1000) if beat
    end

    def rhythm(description)
      @ir['rhythm'] = { 'description' => description }
    end

    def audio(present, description: nil, phase_note: nil)
      @ir['audio_state'] = { 'present' => present }
      @ir['audio_state']['description'] = description if description
      @ir['audio_state']['phase_note'] = phase_note if phase_note
    end

    def narrative(description, unresolved: [])
      @ir['narrative_state'] = { 'description' => description, 'unresolved' => unresolved }
    end

    # --- references and constraints -----------------------------------------

    # `because:` is required. A reference exists to serve an identified requirement; one attached
    # without a reason is the failure mode SPEC/10 §5 is written against.
    def reference(id, role:, weight_ppm:, applies_to:, because:, origin: 'M', detail: nil,
                  digest: nil)
      role = role.to_s.upcase
      raise DSLError, "unknown reference role #{role.inspect}" unless ROLES.include?(role)
      raise DSLError, "reference #{id} must state what requirement it serves" if because.to_s.strip.empty?
      raise DSLError, "reference #{id} must be bound to at least one path" if Array(applies_to).empty?

      entry = {
        'reference_id' => id.to_s, 'role' => role, 'weight_ppm' => weight_ppm,
        'applies_to' => Array(applies_to).map(&:to_s), 'rationale' => because, 'origin' => origin,
        # Present and null rather than absent: the contract distinguishes "not yet bound to bytes"
        # from "this field was never considered".
        'media_digest' => digest
      }
      entry['role_detail'] = detail if detail
      @ir['reference_bindings'] << entry
      note_origin('reference_bindings', origin)
    end

    def media_digest(reference_id, digest)
      ref = @ir['reference_bindings'].find { |r| r['reference_id'] == reference_id.to_s }
      raise DSLError, "no reference #{reference_id.inspect} to attach a digest to" unless ref

      ref['media_digest'] = digest
    end

    def continues(constraint, from_segment: nil, origin: 'M')
      entry = { 'constraint' => constraint }
      entry['source_segment_id'] = from_segment if from_segment
      @ir['continuity_constraints'] << entry
      note_origin('continuity_constraints', origin)
    end

    def forbid(what, because:)
      raise DSLError, "forbidding #{what.inspect} must state why" if because.to_s.strip.empty?

      @ir['negative_constraints'] << { 'forbid' => what, 'rationale' => because }
    end

    def verify(dimension, gte: nil, lte: nil, because:)
      comparator = gte ? 'gte' : 'lte'
      threshold = gte || lte
      raise DSLError, "verify #{dimension} needs gte: or lte:" if threshold.nil?

      @ir['verification_requirements'] << {
        'dimension' => dimension.to_s, 'comparator' => comparator,
        'threshold_mu' => threshold, 'rationale' => because
      }
    end

    # --- ending -------------------------------------------------------------

    def ends_extendable(forbidden: nil)
      @ir['final_frame_requirements'] = {
        'must_be_extendable' => true,
        'forbidden_endings' => forbidden || %w[
          arbitrary_freeze celebration pose fade_out hard_stop
          unexplained_camera_halt artificial_reset neutral_object_reset
        ],
        'unresolved_motion_required' => true,
        'terminal_state_capture' => true
      }
    end

    def concludes
      @ir['final_frame_requirements'] = {
        'must_be_extendable' => false, 'forbidden_endings' => [],
        'unresolved_motion_required' => false, 'terminal_state_capture' => true
      }
    end

    # --- output -------------------------------------------------------------

    def to_ir
      missing = %w[objective scene_mode duration_ms aspect_ratio target_resolution
                   target_frame_rate_mfps environment camera_state].reject { |k| @ir.key?(k) }
      raise DSLError, "scene #{@id} is missing: #{missing.join(', ')}" unless missing.empty?

      # Defaults that are genuinely defaults rather than assumptions about the shot.
      @ir['lighting'] ||= { 'description' => 'unspecified' }
      @ir['atmosphere'] ||= { 'description' => 'unspecified' }
      @ir['visual_style'] ||= { 'description' => 'unspecified' }
      @ir['lens_behavior'] ||= { 'description' => 'unspecified' }
      @ir['animation_timing'] ||= { 'description' => 'unspecified' }
      @ir['rhythm'] ||= { 'description' => 'unspecified' }
      @ir['audio_state'] ||= { 'present' => false }
      @ir['narrative_state'] ||= { 'description' => 'unspecified', 'unresolved' => [] }
      @ir['final_frame_requirements'] ||= ends_extendable

      @ir['origin']['fields'] = @origins.map { |path, origin| { 'path' => path, 'origin' => origin } }
                                        .sort_by { |f| f['path'] }
      @ir
    end

    def to_json_text
      B1::Canon.canonicalize(to_ir)
    end

    def digest
      B1::Canon.b1c1(B1::Canon.digest_value(to_ir))
    end

    private

    def note_origin(path, origin)
      # An unattributed field stays UNKNOWN rather than defaulting to U (law L2).
      @origins[path] = origin
    end

    def stringify(hash)
      hash.transform_keys(&:to_s)
    end
  end

  def self.scene(id, &block)
    scene = Scene.new(id)
    scene.instance_eval(&block)
    scene
  end
end
