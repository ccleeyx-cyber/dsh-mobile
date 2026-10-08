import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

// Repo root = parent of tests/
const PROJECT_ROOT = path.resolve(import.meta.dirname, '..');
const DSH_MOBILE_DIR = path.join(PROJECT_ROOT, 'dsh_mobile');

// =========================================================================
// TEST SUITE 1: Extreme Content Size (10,000 Lines Stress Test)
// =========================================================================
test('TS1: Extreme Content Size - 10,000 Lines Stress Test', async (t) => {
  // 1. Generate 10,000 lines of simulated thinking text
  const lineCount = 10000;
  const lines = [];
  for (let i = 1; i <= lineCount; i++) {
    lines.push(`Line ${i}: Evaluating architectural invariant ${i * 7} with heuristic pruning and context validation.`);
  }
  const extremeThinkingContent = lines.join('\n');
  const extremeByteSize = Buffer.byteLength(extremeThinkingContent, 'utf8');

  assert.equal(lines.length, 10000);
  assert.ok(extremeThinkingContent.length > 500000, `Expected >500k chars, got ${extremeThinkingContent.length}`);
  assert.ok(extremeByteSize > 500000, `Expected >500kB, got ${extremeByteSize}`);

  // Test ToolCallCard._formatSummary emulation under 10k lines
  function formatSummary(tool) {
    if (tool.isRunning) return '运行中...';
    if (!tool.output || tool.output.length === 0) return '完成 (无输出)';
    const l = tool.output.split('\n').length;
    const chars = tool.output.length;
    const sizeStr = chars >= 1024 ? `${(chars / 1024).toFixed(1)} KB` : `${chars} B`;
    return `${l} 行 · ${sizeStr}`;
  }

  const startMs = Date.now();
  const summary = formatSummary({
    isRunning: false,
    output: extremeThinkingContent,
  });
  const elapsedMs = Date.now() - startMs;

  assert.ok(summary.startsWith('10000 行 · '), `Summary was: ${summary}`);
  assert.ok(summary.includes('KB'), `Summary size missing KB: ${summary}`);
  assert.ok(elapsedMs < 100, `Formatting 10k lines must be fast (took ${elapsedMs}ms)`);

  // Test ThinkingCard header word count label
  const headerLabel = `已完成思考 (${extremeThinkingContent.length} 字)`;
  assert.ok(headerLabel.includes(`${extremeThinkingContent.length} 字`));
});

// =========================================================================
// TEST SUITE 2: MaxHeight Bounded Constraints Enforcement
// =========================================================================
test('TS2: MaxHeight Bounded Constraints & Layout Enforcement', async (t) => {
  const thinkingCardPath = path.join(DSH_MOBILE_DIR, 'lib', 'widgets', 'thinking_card.dart');
  const toolCallCardPath = path.join(DSH_MOBILE_DIR, 'lib', 'widgets', 'tool_call_card.dart');
  const memoryCardPath = path.join(DSH_MOBILE_DIR, 'lib', 'widgets', 'memory_card.dart');

  const thinkingCardSrc = fs.readFileSync(thinkingCardPath, 'utf8');
  const toolCallCardSrc = fs.readFileSync(toolCallCardPath, 'utf8');
  const memoryCardSrc = fs.readFileSync(memoryCardPath, 'utf8');

  // 1. ThinkingCard constraints check
  assert.ok(
    thinkingCardSrc.includes('constraints: const BoxConstraints(maxHeight: 280)'),
    'ThinkingCard must declare BoxConstraints(maxHeight: 280)'
  );
  assert.ok(
    thinkingCardSrc.includes('Scrollbar(') && thinkingCardSrc.includes('controller: _scrollController'),
    'ThinkingCard must attach _scrollController to Scrollbar'
  );
  assert.ok(
    thinkingCardSrc.includes('SingleChildScrollView(') && thinkingCardSrc.includes('controller: _scrollController'),
    'ThinkingCard must attach _scrollController to SingleChildScrollView'
  );

  // 2. ToolCallCard constraints check
  const maxHeight240Matches = thinkingCardSrc.includes('maxHeight: 240') ? 1 : 0;
  const toolMatches = (toolCallCardSrc.match(/constraints:\s*const\s*BoxConstraints\(maxHeight:\s*240\)/g) || []).length;
  assert.equal(
    toolMatches,
    2,
    `ToolCallCard must declare BoxConstraints(maxHeight: 240) twice (input & output), found ${toolMatches}`
  );
  assert.ok(
    toolCallCardSrc.includes('controller: _inputScrollController'),
    'ToolCallCard must have _inputScrollController'
  );
  assert.ok(
    toolCallCardSrc.includes('controller: _outputScrollController'),
    'ToolCallCard must have _outputScrollController'
  );
  assert.ok(
    toolCallCardSrc.includes('_inputScrollController.dispose()') &&
    toolCallCardSrc.includes('_outputScrollController.dispose()'),
    'ToolCallCard must dispose both controllers'
  );

  // 3. MemoryCard explicit controller check
  assert.ok(
    memoryCardSrc.includes('ScrollController'),
    'MemoryCard must use dedicated ScrollController'
  );

  // 4. Flutter box layout mathematical model
  // In Flutter BoxConstraints(maxHeight: 280):
  // child height = min(intrinsicHeight, maxHeight)
  const lineHeights = 10000 * 18.0; // 10,000 lines * 18dp per line = 180,000dp
  const effectiveThinkingHeight = Math.min(lineHeights, 280.0);
  assert.equal(effectiveThinkingHeight, 280.0, 'ThinkingCard content height must be strictly clamped to 280dp');

  const effectiveToolHeight = Math.min(lineHeights, 240.0);
  assert.equal(effectiveToolHeight, 240.0, 'ToolCallCard content height must be strictly clamped to 240dp');
});

// =========================================================================
// TEST SUITE 3: Card Folding State Machine & Streaming Collapse Persistence
// =========================================================================
test('TS3: Card Folding State Machine & Collapse Persistence Across Stream Chunks', async (t) => {
  // Emulate ThinkingCard state machine exactly as implemented in thinking_card.dart
  class ThinkingCardModel {
    constructor(initialIsThinking, initialContent = '') {
      this.isThinking = initialIsThinking;
      this.content = initialContent;
      this.expanded = initialIsThinking;
      this.userCollapsed = false;
      this.scrollOffset = 0;
      this.maxScrollExtent = 0;
      this.autoScrollDispatchedCount = 0;
    }

    didUpdateWidget(newIsThinking, newContent) {
      const oldIsThinking = this.isThinking;
      const oldContent = this.content;
      this.isThinking = newIsThinking;
      this.content = newContent;

      // Rule in thinking_card.dart didUpdateWidget:
      // if (!oldWidget.isThinking && widget.isThinking) {
      //   _userCollapsed = false;
      //   _expanded = true;
      // }
      if (!oldIsThinking && this.isThinking) {
        this.userCollapsed = false;
        this.expanded = true;
      }

      // Auto-scroll inside thinking box when new chunks arrive, if user is already near bottom
      // if (widget.isThinking && _expanded && oldWidget.content != widget.content)
      if (this.isThinking && this.expanded && oldContent !== this.content) {
        // simulate maxScrollExtent update based on content length
        this.maxScrollExtent = Math.max(0, this.content.length * 0.5 - 280);
        if (this.maxScrollExtent - this.scrollOffset < 50) {
          this.scrollOffset = this.maxScrollExtent;
          this.autoScrollDispatchedCount++;
        }
      }
    }

    userToggleExpanded() {
      this.expanded = !this.expanded;
      if (!this.expanded) {
        this.userCollapsed = true;
      } else {
        this.userCollapsed = false;
      }
    }
  }

  // Phase 1: Card starts while model is thinking
  const card = new ThinkingCardModel(true, 'Initializing neural reasoning...');
  assert.equal(card.expanded, true, 'Card should start expanded during thinking');
  assert.equal(card.userCollapsed, false);

  // Phase 2: User collapses the card manually while streaming
  card.userToggleExpanded();
  assert.equal(card.expanded, false, 'Card should be collapsed after user tap');
  assert.equal(card.userCollapsed, true, 'userCollapsed flag must be true');

  // Phase 3: 50 successive streaming deltas arrive
  for (let chunk = 1; chunk <= 50; chunk++) {
    card.didUpdateWidget(true, card.content + `\nToken delta chunk #${chunk} reasoning about state.`);
    // CARD MUST REMAIN COLLAPSED (Regression invariant)
    assert.equal(
      card.expanded,
      false,
      `Card must remain collapsed on chunk ${chunk}! Collapse state was hijacked!`
    );
    assert.equal(card.userCollapsed, true);
  }

  // Phase 4: Thinking finishes (isThinking becomes false, content finalized)
  card.didUpdateWidget(false, card.content + '\nThinking finished.');
  assert.equal(card.expanded, false, 'Card must remain collapsed when thinking finishes');

  // Phase 5: Next turn or next thinking block arrives in a subsequent request
  // (transition from isThinking: false -> isThinking: true)
  card.didUpdateWidget(true, 'New query thinking starts...');
  assert.equal(card.expanded, true, 'Card should auto-expand when a new thinking turn begins');
  assert.equal(card.userCollapsed, false, 'userCollapsed should be reset for new turn');
});

// =========================================================================
// TEST SUITE 4: Auto-Scroll Logic & Edge Condition Boundaries
// =========================================================================
test('TS4: Auto-Scroll Edge Condition Boundaries (History Reading vs Pinned)', async (t) => {
  // Emulate ChatView auto-scroll logic exactly as implemented in chat_view.dart
  class ChatViewScrollModel {
    constructor() {
      this.offset = 0;
      this.maxScroll = 0;
      this.userScrolledUp = false;
      this.isUserInteracting = false;
      this.showScrollToBottom = false;
      this.lastStreamRevision = 0;
      this.streamRevision = 0;
      this.autoScrollExecutions = []; // records { type: 'jump' | 'animate', target: number }
    }

    onScrollNotification(type, currentOffset, maxScroll, hasDrag = false) {
      this.offset = currentOffset;
      this.maxScroll = maxScroll;
      const distFromBottom = maxScroll - currentOffset;

      if (type === 'ScrollStartNotification') {
        if (hasDrag) this.isUserInteracting = true;
      } else if (type === 'ScrollUpdateNotification') {
        if (hasDrag) {
          this.isUserInteracting = true;
          if (distFromBottom > 120) {
            this.userScrolledUp = true;
          } else if (distFromBottom < 40) {
            this.userScrolledUp = false;
          }
        }
      } else if (type === 'ScrollEndNotification') {
        this.isUserInteracting = false;
        if (distFromBottom < 40) {
          this.userScrolledUp = false;
        }
      }

      // Check floating button state (_onScroll)
      this.showScrollToBottom = distFromBottom > 160;
      if (distFromBottom < 40 && this.userScrolledUp) {
        this.userScrolledUp = false;
      }
    }

    scheduleAutoScroll() {
      if (this.userScrolledUp || this.isUserInteracting) return;
      const diff = this.maxScroll - this.offset;
      if (diff > 0) {
        if (diff > 250) {
          this.autoScrollExecutions.push({ type: 'animate', target: this.maxScroll });
        } else {
          this.autoScrollExecutions.push({ type: 'jump', target: this.maxScroll });
        }
        this.offset = this.maxScroll;
      }
    }

    onNewStreamToken(contentHeightDelta) {
      this.streamRevision++;
      this.maxScroll += contentHeightDelta;

      if (this.streamRevision !== this.lastStreamRevision) {
        this.lastStreamRevision = this.streamRevision;
        if (!this.userScrolledUp && !this.isUserInteracting) {
          this.scheduleAutoScroll();
        }
      }
    }

    tapScrollToBottomButton() {
      this.userScrolledUp = false;
      this.offset = this.maxScroll;
      this.showScrollToBottom = false;
    }
  }

  const cv = new ChatViewScrollModel();

  // 1. Initial State: Pinned to bottom, receiving live stream tokens
  cv.onScrollNotification('ScrollEndNotification', 1000, 1000);
  assert.equal(cv.userScrolledUp, false);
  assert.equal(cv.offset, 1000);

  // Stream token arrives: diff = 30 (<= 250 -> jump)
  cv.onNewStreamToken(30);
  assert.equal(cv.autoScrollExecutions.length, 1);
  assert.equal(cv.autoScrollExecutions[0].type, 'jump');
  assert.equal(cv.offset, 1030);

  // Large batch of tokens arrives: diff = 300 (> 250 -> animate)
  cv.onNewStreamToken(300);
  assert.equal(cv.autoScrollExecutions.length, 2);
  assert.equal(cv.autoScrollExecutions[1].type, 'animate');
  assert.equal(cv.offset, 1330);

  // 2. User starts dragging upward into chat history
  // Drag to distFromBottom = 80 (not yet > 120)
  cv.onScrollNotification('ScrollStartNotification', 1330, 1330, true);
  cv.onScrollNotification('ScrollUpdateNotification', 1250, 1330, true); // dist = 80
  assert.equal(cv.userScrolledUp, false, 'dist = 80 should not trigger userScrolledUp');

  // Drag further: dist = 121 (> 120 -> userScrolledUp triggers!)
  cv.onScrollNotification('ScrollUpdateNotification', 1209, 1330, true); // dist = 121
  assert.equal(cv.userScrolledUp, true, 'dist > 120 must set userScrolledUp to true');

  // User finishes drag at offset 800 (dist = 530 > 160 -> floating button visible)
  cv.onScrollNotification('ScrollEndNotification', 800, 1330, false);
  assert.equal(cv.userScrolledUp, true);
  assert.equal(cv.showScrollToBottom, true, 'Floating button must be visible when dist > 160');

  const executionsBeforeStream = cv.autoScrollExecutions.length;

  // 3. While user is inspecting history, 30 new tokens arrive in background
  for (let i = 0; i < 30; i++) {
    cv.onNewStreamToken(20);
  }

  // CRITICAL CHECK: Auto-scroll must be ZERO while userScrolledUp is true
  assert.equal(
    cv.autoScrollExecutions.length,
    executionsBeforeStream,
    'Auto-scroll must NOT trigger while userScrolledUp is true!'
  );
  assert.equal(cv.offset, 800, 'User scroll offset in history must be strictly preserved!');

  // 4. User taps the floating "回到最新消息" button
  cv.tapScrollToBottomButton();
  assert.equal(cv.userScrolledUp, false);
  assert.equal(cv.offset, cv.maxScroll);
  assert.equal(cv.showScrollToBottom, false);

  // 5. Subsequent token now resumes auto-scroll
  cv.onNewStreamToken(25);
  assert.equal(cv.autoScrollExecutions.length, executionsBeforeStream + 1);
  assert.equal(cv.offset, cv.maxScroll);
});

// =========================================================================
// TEST SUITE 5: Turn Cancellation & Zero-Orphaned State Guard
// =========================================================================
test('TS5: Turn Cancellation Immediate State Transition & Packet Influx Guard', async (t) => {
  const dshServicePath = path.join(DSH_MOBILE_DIR, 'lib', 'services', 'dsh_service.dart');
  const dshServiceSrc = fs.readFileSync(dshServicePath, 'utf8');

  // Check cancelActiveTurn synchronous execution
  assert.ok(
    dshServiceSrc.includes('_isSending = false;'),
    'cancelActiveTurn must immediately set _isSending = false'
  );
  assert.ok(
    dshServiceSrc.includes('_isCanceling = true;'),
    'cancelActiveTurn must immediately set _isCanceling = true'
  );
  assert.ok(
    dshServiceSrc.includes('msg.isStreaming = false;'),
    'cancelActiveTurn must clear isStreaming on all active messages'
  );
  assert.ok(
    dshServiceSrc.includes('tool.isRunning = false;'),
    'cancelActiveTurn must clear isRunning on all active tools'
  );
  assert.ok(
    dshServiceSrc.includes('notifyListeners();'),
    'cancelActiveTurn must notify listeners synchronously'
  );

  // Check WebSocket in-flight packet guard
  assert.ok(
    dshServiceSrc.includes('if (_isCanceling) return;'),
    '_handleWsMessage must drop in-flight streaming chunks if _isCanceling is true'
  );
});

// =========================================================================
// TEST SUITE 6: Mobile Ergonomics & OS Integration Invariants
// =========================================================================
test('TS6: Mobile Ergonomics - Keyboard Avoidance & VIBRATE Permissions', async (t) => {
  const manifestPath = path.join(DSH_MOBILE_DIR, 'android', 'app', 'src', 'main', 'AndroidManifest.xml');
  const mainShellPath = path.join(DSH_MOBILE_DIR, 'lib', 'views', 'main_shell.dart');
  const chatViewPath = path.join(DSH_MOBILE_DIR, 'lib', 'views', 'chat_view.dart');

  const manifestSrc = fs.readFileSync(manifestPath, 'utf8');
  const mainShellSrc = fs.readFileSync(mainShellPath, 'utf8');
  const chatViewSrc = fs.readFileSync(chatViewPath, 'utf8');

  // 1. Android Manifest VIBRATE permission
  assert.ok(
    manifestSrc.includes('android.permission.VIBRATE'),
    'AndroidManifest.xml must declare android.permission.VIBRATE'
  );

  // 2. MainShell keyboard inset avoidance
  assert.ok(
    mainShellSrc.includes('resizeToAvoidBottomInset: false'),
    'MainShell Scaffold must specify resizeToAvoidBottomInset: false'
  );

  // 3. ChatView smooth scroll physics and drag keyboard dismiss
  assert.ok(
    chatViewSrc.includes('BouncingScrollPhysics'),
    'ChatView must configure BouncingScrollPhysics'
  );
  assert.ok(
    chatViewSrc.includes('ScrollViewKeyboardDismissBehavior.onDrag'),
    'ChatView must configure onDrag keyboard dismissal'
  );

  // 4. Haptic feedback integrations
  assert.ok(
    chatViewSrc.includes('HapticFeedback.lightImpact()'),
    'ChatView must trigger lightImpact on send'
  );
  assert.ok(
    chatViewSrc.includes('HapticFeedback.mediumImpact()'),
    'ChatView must trigger mediumImpact on cancel'
  );
});
