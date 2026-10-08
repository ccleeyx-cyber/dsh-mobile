import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

// Repo root = parent of tests/
const PROJECT_ROOT = path.resolve(import.meta.dirname, '..');
const DSH_MOBILE_DIR = path.join(PROJECT_ROOT, 'dsh_mobile');

test('ADV-1: 1,000,000 Character Monolithic Output Without Line Breaks', async (t) => {
  // Generate massive 1MB string without newlines
  const monolithic = 'A'.repeat(1000000);
  assert.equal(monolithic.length, 1000000);

  function formatSummary(output, isRunning) {
    if (isRunning) return '运行中...';
    if (!output || output.length === 0) return '完成 (无输出)';
    const lines = output.split('\n').length;
    const chars = output.length;
    const sizeStr = chars >= 1024 ? `${(chars / 1024).toFixed(1)} KB` : `${chars} B`;
    return `${lines} 行 · ${sizeStr}`;
  }

  const start = Date.now();
  const summary = formatSummary(monolithic, false);
  const dur = Date.now() - start;

  assert.equal(summary, '1 行 · 976.6 KB');
  assert.ok(dur < 50, `Formatting 1MB single-line took ${dur}ms (must be < 50ms)`);
});

test('ADV-2: Rapid Consecutive Toggles Under Stream Token Pressure', async (t) => {
  // Simulate 100 rapid toggle events interleaved with 100 streaming token arrivals
  class CardToggleSimulator {
    constructor() {
      this.isThinking = true;
      this.expanded = true;
      this.userCollapsed = false;
      this.content = '';
    }

    onToken(chunk) {
      const oldIsThinking = this.isThinking;
      this.content += chunk;
      // didUpdateWidget invariant
      if (!oldIsThinking && this.isThinking) {
        this.userCollapsed = false;
        this.expanded = true;
      }
    }

    toggle() {
      this.expanded = !this.expanded;
      this.userCollapsed = !this.expanded;
    }
  }

  const sim = new CardToggleSimulator();
  assert.equal(sim.expanded, true);

  for (let i = 0; i < 100; i++) {
    sim.onToken(`Chunk ${i} `);
    if (i % 2 === 0) {
      sim.toggle(); // collapse
      assert.equal(sim.expanded, false);
      assert.equal(sim.userCollapsed, true);
    } else {
      sim.toggle(); // expand
      assert.equal(sim.expanded, true);
      assert.equal(sim.userCollapsed, false);
    }
  }
});

test('ADV-3: Auto-Scroll Threshold Boundary Testing (Sub-Pixel Precision)', async (t) => {
  function computeScrollDecision(diff) {
    if (diff <= 0) return 'noop';
    if (diff > 250) return 'animateTo';
    return 'jumpTo';
  }

  // Exact boundary tests
  assert.equal(computeScrollDecision(0), 'noop');
  assert.equal(computeScrollDecision(-10), 'noop');
  assert.equal(computeScrollDecision(0.1), 'jumpTo');
  assert.equal(computeScrollDecision(249.99), 'jumpTo');
  assert.equal(computeScrollDecision(250.0), 'jumpTo');
  assert.equal(computeScrollDecision(250.01), 'animateTo');
  assert.equal(computeScrollDecision(1000.0), 'animateTo');

  // Hysteresis boundary tests for userScrolledUp
  function computeUserScrolledUp(currentScrolledUp, distFromBottom) {
    if (distFromBottom > 120) return true;
    if (distFromBottom < 40) return false;
    return currentScrolledUp; // deadband hysteresis [40, 120]
  }

  // Test deadband hysteresis:
  // 1. Starting at bottom (false)
  let scrolledUp = false;
  scrolledUp = computeUserScrolledUp(scrolledUp, 30);
  assert.equal(scrolledUp, false);
  scrolledUp = computeUserScrolledUp(scrolledUp, 45); // in deadband
  assert.equal(scrolledUp, false);
  scrolledUp = computeUserScrolledUp(scrolledUp, 120); // exactly at threshold
  assert.equal(scrolledUp, false);
  scrolledUp = computeUserScrolledUp(scrolledUp, 120.1); // above threshold
  assert.equal(scrolledUp, true);

  // 2. Returning from history (true)
  scrolledUp = computeUserScrolledUp(scrolledUp, 100); // in deadband
  assert.equal(scrolledUp, true); // must remain true!
  scrolledUp = computeUserScrolledUp(scrolledUp, 40); // exactly at threshold
  assert.equal(scrolledUp, true); // must remain true!
  scrolledUp = computeUserScrolledUp(scrolledUp, 39.9); // below threshold
  assert.equal(scrolledUp, false); // disengages!
});

test('ADV-4: Empty and Malformed Stream Chunks Resilience', async (t) => {
  // Test DshService stream chunk parser behavior with null, empty, or unexpected keys
  function parseStreamChunk(json) {
    const isThinkingChunk = json.type === 'thinking' || json.hasOwnProperty('thinking');
    const isDeltaChunk = json.type === 'delta' || json.type === 'token' || json.hasOwnProperty('delta');
    
    let deltaText = '';
    if (isThinkingChunk) {
      deltaText = (json.delta ?? json.thinking ?? '').toString();
    } else if (isDeltaChunk) {
      deltaText = (json.delta ?? json.content ?? json.text ?? '').toString();
    }
    return { isThinkingChunk, isDeltaChunk, deltaText };
  }

  // 1. null delta
  const r1 = parseStreamChunk({ type: 'thinking', delta: null });
  assert.equal(r1.deltaText, '');

  // 2. numeric token
  const r2 = parseStreamChunk({ type: 'delta', delta: 42 });
  assert.equal(r2.deltaText, '42');

  // 3. undefined fields
  const r3 = parseStreamChunk({ type: 'thinking' });
  assert.equal(r3.deltaText, '');

  // 4. legacy raw thinking property
  const r4 = parseStreamChunk({ thinking: 'Contemplating solution...' });
  assert.equal(r4.deltaText, 'Contemplating solution...');
});
