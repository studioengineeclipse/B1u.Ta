/// Checks for the canon and the authority presenter.
///
/// The presenter's property under test is that an approval request cannot be rendered while
/// omitting something the approver needs. A surface that renders a missing scope as a blank line
/// produces an approval that looks informed and is not.
library;

import 'canon.dart';
import 'presenter.dart';

int _failures = 0;

void _check(String what, bool condition, [String detail = '']) {
  if (condition) {
    print('  ok    $what');
  } else {
    print('  FAIL  $what${detail.isEmpty ? '' : '\n        $detail'}');
    _failures++;
  }
}

Map<String, Object?> _envelope({String effectClass = 'REVERSIBLE'}) => {
      'envelope_id': 'env-1',
      'proposed_action': {'kind': 'write_files', 'summary': 'Build the system described in the plan'},
      'target': '/home/user/B1u.Ta',
      'scope': ['repo_write', 'branch_push'],
      'expected_effect': 'Files created and committed on the designated branch',
      'relevant_state_digest': 'b1c1:${'a' * 64}',
      'plan_digest': 'b1c1:${'b' * 64}',
      'causal_objective': 'Deliver the orchestrator',
      'effect_class': effectClass,
      'authorized_by': 'user',
      'max_age_ms': 3600000,
    };

int runSelfTest() {
  _failures = 0;

  print('b1-canon-1 (dart)');
  _check('{} digest matches the published value',
      digestText('{}') == '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a');
  _check('[] digest matches the published value',
      digestText('[]') == '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945');
  _check('member order and whitespace are irrelevant',
      digestText('{"b":1,"a":2}') == digestText('  { "a" : 2 , "b" : 1 }  '));
  _check('an escaped surrogate pair equals the literal character',
      digestText(r'{"x":"🎬"}') == digestText('{"x":"\u{1F3AC}"}'));

  for (final entry in {
    '{"a":1.5}': 'B1_ERR_NONINTEGER_NUMBER',
    '{"a":9007199254740992}': 'B1_ERR_NONINTEGER_NUMBER',
    '{"a b":1}': 'B1_ERR_KEY_SYNTAX',
    '{"a":1,"a":2}': 'B1_ERR_DUPLICATE_KEY',
    r'{"a":"\ud83c"}': 'B1_ERR_INVALID_UTF8',
  }.entries) {
    try {
      digestText(entry.key);
      _check('${entry.key} rejected', false, 'it was accepted');
    } on B1Error catch (e) {
      _check('${entry.key} rejected as ${entry.value}', e.token == entry.value, 'got ${e.token}');
    }
  }

  print('authority presenter');

  {
    final req = ApprovalRequest(_envelope());
    final text = req.render();
    _check('the rendered request names what is authorized', text.contains('Build the system'));
    _check('it lists the scope explicitly', text.contains('repo_write') && text.contains('branch_push'));
    _check('it says that nothing outside the scope is authorized',
        text.contains('nothing outside this list is authorized'));
    _check('it states reversibility in words, not only as a code',
        text.contains('The original state can reasonably be restored'));
    _check('it says the authorization can go stale', text.contains('goes stale'));
    _check('it says the check happens again at effect time',
        text.contains('checked again immediately before the effect occurs'));
    _check('it shows what the approval is bound to', text.contains(req.bindingDigest));
    _check('a reversible effect carries no irreversibility warning', !text.contains('⚠'));
  }

  {
    final text = ApprovalRequest(_envelope(effectClass: 'IRREVERSIBLE')).render();
    _check('an irreversible effect is flagged', text.contains('⚠'));
    _check('the flag says why it matters', text.contains('cannot be relied on to be undone'));
  }

  {
    final text = ApprovalRequest(_envelope(effectClass: 'UNKNOWN')).render();
    _check('an unknown reversibility is flagged as well as an irreversible one', text.contains('⚠'));
    _check('it says nobody knows whether it can be undone',
        text.contains('reversibility nobody knows'));
  }

  {
    // The property that matters: a missing field is refused, not rendered blank.
    for (final field in ['scope', 'effect_class', 'target', 'expected_effect']) {
      final broken = _envelope()..remove(field);
      try {
        ApprovalRequest(broken);
        _check('an envelope missing `$field` is refused', false, 'it rendered anyway');
      } on PresentationError catch (e) {
        _check('an envelope missing `$field` is refused', e.missing.contains(field));
      }
    }
  }

  {
    // The binding digest must move when anything material moves, since that is what closes the gate.
    final a = ApprovalRequest(_envelope()).bindingDigest;
    final drifted = _envelope()..['plan_digest'] = 'b1c1:${'c' * 64}';
    final b = ApprovalRequest(drifted).bindingDigest;
    _check('the binding digest changes when the plan changes', a != b);

    final rescoped = _envelope()..['scope'] = ['repo_write'];
    _check('the binding digest changes when the scope changes',
        a != ApprovalRequest(rescoped).bindingDigest);
  }

  print('continuity chain');
  {
    final text = renderContinuityChain([
      {
        'segment_id': 'shot-01',
        'verified': true,
        'final_frame_visual_signature': 'a' * 64,
        'unresolved_motion': ['still walking'],
      },
      {'segment_id': 'shot-02', 'verified': false, 'unresolved_motion': ['mid-turn']},
    ]);
    _check('verified history is distinguished from a candidate',
        text.contains('VERIFIED — hard temporal history') &&
            text.contains('CANDIDATE — no authority over what follows'));
    _check('what a segment carries forward is shown', text.contains('still walking'));
  }

  {
    final text = renderContinuityChain([
      {'segment_id': 'shot-01', 'verified': true, 'unresolved_motion': []},
    ]);
    _check('a verified segment with nothing unresolved is called out',
        text.contains('forecloses continuation'));
  }

  _check('an empty chain says so plainly',
      renderContinuityChain([]).contains('The chain begins'));

  print('');
  print(_failures == 0 ? 'PASSED: 0 failures' : 'FAILED: $_failures failure(s)');
  return _failures == 0 ? 0 : 1;
}
