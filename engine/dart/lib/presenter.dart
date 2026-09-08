/// The authority envelope presenter. Normative: SPEC/40-authority-gate.md.
///
/// Dart owns the approval surface: the thing a person actually reads before authorizing a
/// persistent effect. Its job is to make the envelope legible enough that the approval means
/// something — an approval given against a summary that omitted the scope, the reversibility, or
/// what happens if the plan drifts is not informed consent, it is a rubber stamp.
///
/// So the presenter refuses to render an envelope that is missing a field the approver needs, and
/// it always states the four things an approver most needs and is most likely to be denied:
/// what exactly is authorized, what is *not*, whether it can be undone, and when the authorization
/// goes stale.
///
/// Pure Dart with no Flutter dependency: the presentation logic is testable on its own, and a
/// Flutter shell is a rendering surface on top rather than a prerequisite.
library;

import 'canon.dart';

/// A field the approver must see. Absent ones are reported rather than rendered as blank.
const List<String> requiredEnvelopeFields = [
  'envelope_id',
  'proposed_action',
  'target',
  'scope',
  'expected_effect',
  'relevant_state_digest',
  'plan_digest',
  'causal_objective',
  'effect_class',
  'authorized_by',
  'max_age_ms',
];

const Map<String, String> effectClassMeaning = {
  'REVERSIBLE': 'The original state can reasonably be restored.',
  'COMPENSATABLE': 'This cannot simply be reversed, but a corrective action can materially '
      'compensate for it.',
  'IRREVERSIBLE': 'Once applied this cannot reasonably be undone.',
  'UNKNOWN': 'Recovery characteristics could not be established. Approving this means accepting an '
      'effect whose reversibility nobody knows.',
};

class PresentationError implements Exception {
  final List<String> missing;

  PresentationError(this.missing);

  @override
  String toString() =>
      'the envelope is missing ${missing.join(', ')}; an approval given without these is not informed';
}

class ApprovalRequest {
  final Map<String, Object?> envelope;

  ApprovalRequest(this.envelope) {
    final missing = requiredEnvelopeFields.where((f) => envelope[f] == null).toList();
    if (missing.isNotEmpty) throw PresentationError(missing);
  }

  String get id => envelope['envelope_id'] as String;

  String get effectClass => envelope['effect_class'] as String;

  List<String> get scope =>
      (envelope['scope'] as List).map((e) => e.toString()).toList();

  /// The digest the gate will recompute at effect time. Shown because it is the mechanism that
  /// makes the approval specific: if the state or plan drifts, this changes and the gate closes.
  String get bindingDigest => b1c1(digestValue({
        'action': envelope['proposed_action'],
        'target': envelope['target'],
        'scope': envelope['scope'],
        'expected_effect': envelope['expected_effect'],
        'relevant_state_digest': envelope['relevant_state_digest'],
        'plan_digest': envelope['plan_digest'],
        'causal_objective': envelope['causal_objective'],
      }));

  String get durationDescription {
    final ms = envelope['max_age_ms'] as int;
    if (ms < 60000) return '${ms ~/ 1000} seconds';
    if (ms < 3600000) return '${ms ~/ 60000} minutes';
    return '${ms ~/ 3600000} hours';
  }

  /// Renders the request as plain text for a terminal or a Flutter surface.
  String render() {
    final b = StringBuffer();
    final action = envelope['proposed_action'];
    final actionSummary = action is Map ? (action['summary'] ?? action['kind']) : action;

    b.writeln('AUTHORIZATION REQUESTED');
    b.writeln('');
    b.writeln('  What      $actionSummary');
    b.writeln('  Target    ${envelope['target']}');
    b.writeln('  Because   ${envelope['causal_objective']}');
    b.writeln('  Expected  ${envelope['expected_effect']}');
    b.writeln('');

    b.writeln('  Authorized scope — nothing outside this list is authorized:');
    for (final s in scope) {
      b.writeln('    • $s');
    }
    b.writeln('');

    b.writeln('  Reversibility  $effectClass');
    b.writeln('    ${effectClassMeaning[effectClass] ?? 'Unrecognised effect class.'}');
    b.writeln('');

    b.writeln('  This authorization goes stale if the action, target, scope, expected effect,');
    b.writeln('  assumed state or plan changes, and expires after $durationDescription.');
    b.writeln('  It is checked again immediately before the effect occurs, not only now.');
    b.writeln('');
    b.writeln('  Bound to  $bindingDigest');
    b.writeln('  Requested by  ${envelope['authorized_by']}');

    if (effectClass == 'IRREVERSIBLE' || effectClass == 'UNKNOWN') {
      b.writeln('');
      b.writeln('  ⚠ This effect cannot be relied on to be undone. Recovery limits are stated');
      b.writeln('    before authorization precisely so they are not discovered afterwards.');
    }
    return b.toString();
  }

  /// The machine-readable form, for a UI that renders its own layout.
  Map<String, Object?> toPresentation() => {
        'envelope_id': id,
        'summary': envelope['expected_effect'],
        'target': envelope['target'],
        'scope': envelope['scope'],
        'effect_class': effectClass,
        'effect_class_meaning': effectClassMeaning[effectClass] ?? 'Unrecognised effect class.',
        'binding_digest': bindingDigest,
        'expires_after': durationDescription,
        'revalidated_at_effect_time': true,
        'warns_irreversible': effectClass == 'IRREVERSIBLE' || effectClass == 'UNKNOWN',
      };
}

/// Renders a continuity chain: which segments are verified history and which are still candidates.
///
/// The distinction is the point. Only a verified segment is hard temporal history; a generated but
/// unverified one has no authority over what follows, and a chain view that drew them identically
/// would suggest continuity the sequence has not earned.
String renderContinuityChain(List<Map<String, Object?>> segments) {
  if (segments.isEmpty) {
    return 'No segments. The chain begins once a first segment is generated and verified.';
  }

  final b = StringBuffer();
  b.writeln('CONTINUITY CHAIN');
  b.writeln('');

  for (var i = 0; i < segments.length; i++) {
    final s = segments[i];
    final verified = s['verified'] == true;
    final marker = verified ? '━━' : '┈┈';
    final label = verified ? 'VERIFIED — hard temporal history' : 'CANDIDATE — no authority over what follows';

    b.writeln('  ${s['segment_id'] ?? 'segment-$i'}   $label');
    if (s['final_frame_visual_signature'] != null) {
      b.writeln('    terminal signature  ${(s['final_frame_visual_signature'] as String).substring(0, 16)}…');
    }
    final unresolved = s['unresolved_motion'];
    if (unresolved is List && unresolved.isNotEmpty) {
      b.writeln('    carries forward     ${unresolved.join('; ')}');
    } else if (verified) {
      b.writeln('    carries forward     nothing — this ending forecloses continuation');
    }
    if (i < segments.length - 1) b.writeln('        $marker');
  }
  return b.toString();
}
