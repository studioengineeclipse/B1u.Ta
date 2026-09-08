# frozen_string_literal: true

# The third segment of the corridor sequence, written in the authoring DSL.
#
# Compile with:  ruby surfaces/ruby/compile_dsl.rb examples/shot-03-continuation.b1.rb
#
# Compare this with examples/shot-02-continuation.json — the same kind of specification, at about a
# third of the length, and with the constraints that matter (a reference must state its purpose, a
# prohibition must state its reason) enforced at authoring time rather than in review.

B1.scene 'shot-03' do
  objective 'Continue from the second segment: the courier reaches the pipework junction and ' \
            'turns the corner, still mid-stride, with the camera following through the turn.'
  mode :continuation
  seconds 4
  aspect 16, 9
  resolution 1920, 1080
  frame_rate '23.976' # exact: 23976 milli-fps, no Float involved

  character :kage,
            name: 'Kage',
            description: 'Adult courier, medium build, close-cropped dark hair, canvas satchel ' \
                         'on the left shoulder',
            identity_anchor: 'Facial structure, the scar through the right eyebrow, and the ' \
                             'satchel strap crossing right-shoulder-to-left-hip',
            costume: 'Charcoal work jacket over a grey shirt, dark trousers, worn boots'

  identity_constraint :kage, 'Scar through the right eyebrow stays visible when the face turns ' \
                             'toward camera', tolerance_mu: 150
  identity_constraint :kage, 'Satchel stays on the left shoulder', tolerance_mu: 50

  prop :satchel, name: 'Canvas satchel', description: 'Worn canvas bag, strap across the body'

  environment 'The corridor junction: the pipework turns left, the corridor opens into a wider bay',
              layout: 'Subject moves right, then turns left at the junction; camera follows ' \
                      'through the turn holding the subject at one-third frame width'

  depth_layer 0, 'Foreground: the pipework junction passing camera-left'
  depth_layer 1, 'Midground: the subject turning'
  depth_layer 2, 'Background: the bay beyond the junction, dimmer than the corridor'

  element :foreground, :junction, name: 'Pipe junction',
          description: 'The elbow where the pipework turns, passing close to camera'

  lighting 'Strip-lights continue overhead; the bay beyond is lit more dimly, so the subject ' \
           'moves into a slightly darker pool as the turn completes',
           key_direction: 'directly overhead, slightly behind'
  atmosphere 'Cool, still air; the haze thins in the wider bay'
  style 'Naturalistic, neutral colour with a slight cool cast'

  material 'Canvas satchel', behaves: 'swings wider through the turn as the body rotates, then ' \
                                      'settles back against the hip'
  material 'Jacket', behaves: 'creases across the back as the shoulders rotate into the turn'

  camera framing: 'medium shot, subject at roughly one-third frame width',
         focal_mm: 35,
         position_mm: { x: -2000, y: 1500, z: 0 }

  camera_move :track, from: 0, to: '2.5', metres: '2.1',
              framing_note: 'continuing the lateral speed inherited from the previous segment ' \
                            'without acceleration'
  camera_move :orbit, from: '2.5', to: 4, degrees: 65,
              framing_note: 'following the subject through the turn, keeping them at one-third ' \
                            'frame width rather than letting them drift to centre'

  lens 'Fixed 35mm equivalent, no zoom',
       focus: 'stays on the subject through the turn; the passing junction goes soft'

  motion :kage, 'walks at a steady pace, then rotates through the turn without breaking stride',
         from: 0, to: 4,
         starting_phase: 'mid-stride, right foot in contact, left leg swinging forward',
         ending_phase: 'mid-stride through the turn, left foot in contact, body rotated about ' \
                       '65 degrees from the entry heading'

  secondary_motion :satchel, behaves: 'swings outward through the rotation, lagging the body'

  interaction :junction, 'briefly occludes', :kage, from: '1.8', to: '2.4'

  physics :kage, 'Feet make and break contact without sliding; the turn is driven by a visible ' \
                 'weight shift rather than the body pivoting on the spot'
  physics :satchel, 'Swings under gravity, constrained by the strap; does not intersect the body'

  timing 'Steady gait cycle of roughly 1.1 seconds per stride, unchanged through the turn',
         beat: '1.1'
  rhythm 'Even; the turn does not slow the walk'

  audio true,
        description: 'Footsteps on concrete, reverb opening out as the bay widens',
        phase_note: 'The first footstep lands mid-step, continuing the cadence from segment two'

  narrative 'The courier reaches the junction, still carrying the undelivered package',
            unresolved: ['The package has not been delivered', 'The bay has not been crossed']

  reference :ref_kage_identity, role: :character_identity, weight_ppm: 900_000,
            applies_to: %w[characters identity_constraints],
            because: 'Preserve the courier across the whole sequence',
            origin: 'U'

  reference :ref_prev_segment, role: :video_continuity, weight_ppm: 1_000_000,
            applies_to: %w[subject_motion camera_motion continuity_constraints animation_timing],
            because: 'Segment two is verified history; the gait phase and camera speed continue ' \
                     'from its terminal state'

  reference :ref_corridor_plate, role: :environment, weight_ppm: 700_000,
            applies_to: %w[environment depth_layers lighting],
            because: 'Hold the corridor geometry and light spacing established in segment one'

  continues 'The first frame continues the gait from segment two: right foot in contact, left ' \
            'leg swinging', from_segment: 'shot-02'
  continues 'Camera lateral velocity matches segment two at the cut; the move does not restart',
            from_segment: 'shot-02'
  continues 'The satchel is mid-swing on the left shoulder, as at the previous terminal frame',
            from_segment: 'shot-02'

  forbid 'the subject stopping at the junction or looking back',
         because: 'Breaks the continuous walk the sequence is built on and forecloses the next segment'
  forbid 'the bay revealing a character or event not in the specification',
         because: 'Introduces a narrative the following segments have not accounted for'
  forbid 'a cut, dissolve or fade within the take',
         because: 'The segment must be one continuous camera take'

  verify :character_identity_mu, gte: 700,
         because: 'Identity drift compounds across a chained sequence'
  verify :continuity_start_mu, gte: 750,
         because: 'The first frame must be causally compatible with segment two'
  verify :continuity_end_mu, gte: 700,
         because: 'The turn must leave an extendable state for segment four'
  verify :artifact_severity_mu, lte: 250,
         because: 'Artifacts compound across a chained sequence'

  ends_extendable
end
