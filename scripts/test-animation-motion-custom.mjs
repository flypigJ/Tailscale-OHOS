import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../entry/src/main/ets/components/MotionTokens.ets', import.meta.url), 'utf8')
  .replace(/^import[^\n]+\n/gm, '').replace(/^export /gm, '');

function fixture(settings = { preset: -1, duration: 60, amplitude: 56, damping: 64 }) {
  const calls = [];
  const makeCurve = (kind, parameters) => {
    const curve = { kind, parameters };
    calls.push(curve);
    return curve;
  };
  const sandbox = {
    curves: {
      springCurve: (...parameters) => makeCurve('springCurve', parameters),
      cubicBezierCurve: (...parameters) => makeCurve('cubicBezierCurve', parameters)
    },
    AnimationPreferences: { current: () => settings }
  };
  vm.runInNewContext(stripTypeScriptTypes(source) + '\nthis.Tokens = MotionTokens;', sandbox);
  return { Tokens: sandbox.Tokens, calls, settings };
}

test('custom settings retain a duration-controlled spring curve', () => {
  const { Tokens } = fixture();
  const custom = { preset: -1, duration: 60, amplitude: 56, damping: 64 };
  assert.deepEqual(Tokens.curveFor(custom), {
    kind: 'springCurve', parameters: [0.56 * 0.18, 1, 210 + 0.56 * 90, 14 + 0.64 * 18]
  });
  assert.deepEqual(Tokens.curveFor(custom), Tokens.curveFor({ ...custom, preset: 2 }));
});

test('custom duration changes the supplied duration without changing spring shape', () => {
  const { Tokens, settings } = fixture();
  const before = Tokens.curve();
  const fastDuration = Tokens.duration(400);
  settings.duration = 100;
  assert.equal(Tokens.duration(400), 520);
  assert.notEqual(Tokens.duration(400), fastDuration);
  assert.deepEqual(Tokens.curve(), before);
  settings.duration = 0;
  assert.equal(Tokens.duration(400), 220);
  assert.equal(Tokens.PAGE, Tokens.durationFor(320, 0));
});

test('custom amplitude changes both travel scale and spring parameters without changing damping', () => {
  const { Tokens, settings } = fixture();
  settings.amplitude = 0;
  const low = Tokens.curve();
  const shortTravel = Tokens.amplitude(38);
  settings.amplitude = 100;
  const high = Tokens.curve();
  assert.equal(low.kind, 'springCurve');
  assert.equal(high.kind, 'springCurve');
  assert.equal(shortTravel, 38 * 0.55);
  assert.equal(Tokens.amplitude(38), 38 * 1.35);
  assert.equal(low.parameters[0], 0);
  assert.equal(high.parameters[0], 0.18);
  assert.equal(low.parameters[2], 210);
  assert.equal(high.parameters[2], 300);
  assert.equal(low.parameters[3], high.parameters[3]);
});

test('custom damping changes the physical damping coefficient independently', () => {
  const { Tokens, settings } = fixture();
  settings.damping = 0;
  const low = Tokens.curve();
  settings.damping = 100;
  const high = Tokens.curve();
  assert.equal(low.kind, 'springCurve');
  assert.equal(high.kind, 'springCurve');
  assert.deepEqual(low.parameters.slice(0, 3), high.parameters.slice(0, 3));
  assert.equal(low.parameters[3], 14);
  assert.equal(high.parameters[3], 32);
  assert.equal(Tokens.duration(400), Tokens.durationFor(400, settings.duration));
});

test('existing efficiency, default and lively preset curves retain their formulas', () => {
  const { Tokens } = fixture();
  const base = { duration: 60, amplitude: 56, damping: 64 };
  assert.deepEqual(Tokens.curveFor({ ...base, preset: 0 }), {
    kind: 'cubicBezierCurve', parameters: [0.18, 0, 0.24 + 0.64 * 0.12, 1]
  });
  assert.deepEqual(Tokens.curveFor({ ...base, preset: 1 }), {
    kind: 'cubicBezierCurve', parameters: [0.24 + 0.64 * 0.08, 0, 0.18 + 0.56 * 0.1, 1]
  });
  assert.deepEqual(Tokens.curveFor({ ...base, preset: 2 }), {
    kind: 'springCurve', parameters: [0.56 * 0.18, 1, 210 + 0.56 * 90, 14 + 0.64 * 18]
  });
});

test('manual controls remain bounded at their existing endpoints', () => {
  const { Tokens } = fixture();
  assert.equal(Tokens.durationFor(400, -20), 220);
  assert.equal(Tokens.durationFor(400, 120), 520);
  assert.equal(Tokens.amplitudeScale(-20), 0.55);
  assert.equal(Tokens.amplitudeScale(120), 1.35);
  assert.deepEqual(Tokens.curveFor({ preset: -1, duration: 60, amplitude: -20, damping: 120 }), {
    kind: 'springCurve', parameters: [0, 1, 210, 32]
  });
});
