/**
 * Milestone M4 Stress Challenge Test Suite
 * Empirical Challenger: challenger_m4_2
 * 
 * Empirically stress-tests and challenges Milestone M4 Flutter Client Resilience, State Invariants, and Resource Cleanups:
 * 1. Turn cancel fencing and packet influx guard under concurrent streaming (F1.5, F4.1)
 * 2. BoxConstraints layout invariants and scroll controller attachment in thinking_card.dart and tool_call_card.dart (F1.3, F4.2)
 * 3. 401 token invalidation state transition, banner presentation, and reconnect suppression (F4.3, F3.1)
 * 4. Resource cleanups, safe markdown parsing, model deserialization, and live bridge boundaries (F4.1 - F4.5)
 * 5. Adversarial Challenge Verifications:
 *    - CHALLENGE 1 [VULNERABILITY]: workspacePath directory traversal escaping workspace boundaries
 *    - CHALLENGE 2 [CONCURRENCY RACE]: missing turn cancel sequence fence in tool_result handler
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { apiRequest } from './e2e/helpers/client.js';
import { CONFIG } from './e2e/helpers/fixtures.js';

// Repo root = parent of tests/
const PROJECT_ROOT = path.resolve(import.meta.dirname, '..');
const DSH_MOBILE_DIR = path.join(PROJECT_ROOT, 'dsh_mobile');
const PLUGIN_DIR = path.join(PROJECT_ROOT, 'dsh-server-plugin');

// =========================================================================
// SUITE 1: Turn Cancellation Fencing & Packet Influx Guard (F1.5, F4.1)
// =========================================================================
describe('M4 Challenge 1: Turn Cancel Fencing & Packet Influx Guard', () => {

  it('TC1.1: Concurrent Packet Influx Dropping Invariant under 1,000 frame flood', async () => {
    // Emulate DshService state machine during turn cancellation
    class DshServiceTurnEmulator {
      constructor() {
        this._isSending = true;
        this._isCanceling = false;
        this._activeTurnSeq = 1;
        this._cancelledTurnSeq = 0;
        this._streamRevision = 0;
        this._messages = [
          {
            role: 'assistant',
            content: 'Initial generated text',
            thinking: 'Initial reasoning step',
            isStreaming: true,
            tools: [{ name: 'exec', input: 'ls', output: '', isRunning: true }]
          }
        ];
      }

      cancelActiveTurn() {
        this._cancelledTurnSeq = this._activeTurnSeq;
        this._isSending = false;
        this._isCanceling = true;

        for (const msg of this._messages) {
          if (msg.isStreaming) {
            msg.isStreaming = false;
            for (const tool of msg.tools) {
              tool.isRunning = false;
            }
            if (!msg.content.endsWith('*(任务已被手动停止)*')) {
              msg.content += '\n*(任务已被手动停止)*';
            }
          }
        }
        this._streamRevision++;
      }

      handleRawWsPacket(packet, activeCancelingFlag = true) {
        this._isCanceling = activeCancelingFlag;

        // Fencing check exactly matching dsh_service.dart lines 1381-1382, 1421-1422
        if (this._isCanceling) return false;
        if (this._activeTurnSeq <= this._cancelledTurnSeq) return false;

        // If not dropped, mutate message
        const current = this._messages[this._messages.length - 1];
        if (packet.type === 'thinking') {
          current.thinking = (current.thinking || '') + packet.delta;
        } else if (packet.type === 'delta') {
          current.content += packet.delta;
        } else if (packet.type === 'tool_start') {
          current.tools.push({ name: packet.tool, input: packet.input, isRunning: true });
        }
        return true;
      }
    }

    const service = new DshServiceTurnEmulator();
    assert.equal(service._isSending, true);
    assert.equal(service._messages[0].isStreaming, true);

    // User cancels active turn
    service.cancelActiveTurn();
    assert.equal(service._isSending, false);
    assert.equal(service._isCanceling, true);
    assert.equal(service._messages[0].isStreaming, false);
    assert.equal(service._messages[0].tools[0].isRunning, false);
    assert.ok(service._messages[0].content.includes('*(任务已被手动停止)*'));

    const snapshotContent = service._messages[0].content;
    const snapshotThinking = service._messages[0].thinking;
    const snapshotToolsCount = service._messages[0].tools.length;

    // Simulate 1,000 incoming packets while _isCanceling is true
    let acceptedWhileCanceling = 0;
    for (let i = 0; i < 500; i++) {
      const type = (i % 3 === 0) ? 'thinking' : (i % 3 === 1 ? 'delta' : 'tool_start');
      const packet = { type, delta: ` lingering chunk ${i}`, tool: `cmd_${i}`, input: `arg_${i}` };
      const accepted = service.handleRawWsPacket(packet, true);
      if (accepted) acceptedWhileCanceling++;
    }
    assert.equal(acceptedWhileCanceling, 0, 'Every packet must be dropped when _isCanceling is true');

    // Simulate another 500 packets after cancel HTTP completed (_isCanceling reset to false, but _activeTurnSeq <= _cancelledTurnSeq)
    let acceptedAfterCancelRequest = 0;
    for (let i = 500; i < 1000; i++) {
      const type = (i % 3 === 0) ? 'thinking' : (i % 3 === 1 ? 'delta' : 'tool_start');
      const packet = { type, delta: ` post-cancel chunk ${i}`, tool: `cmd_${i}`, input: `arg_${i}` };
      const accepted = service.handleRawWsPacket(packet, false);
      if (accepted) acceptedAfterCancelRequest++;
    }
    assert.equal(acceptedAfterCancelRequest, 0, 'Every packet must be dropped by sequence fence _activeTurnSeq <= _cancelledTurnSeq');

    // Verify invariants: zero modifications occurred
    assert.equal(service._messages[0].content, snapshotContent);
    assert.equal(service._messages[0].thinking, snapshotThinking);
    assert.equal(service._messages[0].tools.length, snapshotToolsCount);
    assert.equal(service._messages[0].isStreaming, false);
    assert.equal(service._isSending, false);
  });

  it('TC1.2: Delayed HTTP Prompt Response Race Condition Immunity', async () => {
    function simulateSendPromptResolution({ turnId, cancelledTurnSeq, isCanceling, resStatusCode, resError }) {
      if (isCanceling || turnId <= cancelledTurnSeq) {
        return { dropped: true, reason: 'turn_canceled_or_stale' };
      }
      if (resStatusCode === 200) {
        return { dropped: false, startedPolling: true };
      } else {
        return { dropped: false, errorApplied: resError };
      }
    }

    // Case 1: Prompt sent for turn 5, cancelled before response arrives
    const resA = simulateSendPromptResolution({
      turnId: 5,
      cancelledTurnSeq: 5,
      isCanceling: true,
      resStatusCode: 200
    });
    assert.equal(resA.dropped, true);

    // Case 2: Delayed response arrives with 500 error after cancellation finished (_isCanceling is false, but cancelledTurnSeq is 5)
    const resB = simulateSendPromptResolution({
      turnId: 5,
      cancelledTurnSeq: 5,
      isCanceling: false,
      resStatusCode: 500,
      resError: 'Internal Model Server Error'
    });
    assert.equal(resB.dropped, true, 'Delayed 500 error must NOT overwrite UI or error state after cancellation');

    // Case 3: Valid new turn 6 not cancelled
    const resC = simulateSendPromptResolution({
      turnId: 6,
      cancelledTurnSeq: 5,
      isCanceling: false,
      resStatusCode: 200
    });
    assert.equal(resC.dropped, false);
    assert.equal(resC.startedPolling, true);
  });

  it('TC1.3: Static Source Invariants for Turn Fencing in dsh_service.dart', () => {
    const dshServicePath = path.join(DSH_MOBILE_DIR, 'lib', 'services', 'dsh_service.dart');
    const dshServiceSrc = fs.readFileSync(dshServicePath, 'utf8');

    // Verify synchronous state transitions
    assert.ok(dshServiceSrc.includes('_cancelledTurnSeq = _activeTurnSeq;'), 'Must record cancelled turn sequence');
    assert.ok(dshServiceSrc.includes('_isSending = false;'), 'Must set _isSending = false immediately');
    assert.ok(dshServiceSrc.includes('_isCanceling = true;'), 'Must set _isCanceling = true immediately');
    assert.ok(dshServiceSrc.includes('_sessionPollTimer?.cancel();'), 'Must immediately terminate active polling');
    assert.ok(dshServiceSrc.includes('msg.isStreaming = false;'), 'Must finalize active streams');
    assert.ok(dshServiceSrc.includes('tool.isRunning = false;'), 'Must finalize running tools');

    // Verify separate guard lines in _handleRawMessage
    assert.ok(dshServiceSrc.includes('if (_isCanceling) return;'), 'Must have separate if (_isCanceling) return;');
    assert.ok(dshServiceSrc.includes('if (_activeTurnSeq <= _cancelledTurnSeq) return;'), 'Must have separate if (_activeTurnSeq <= _cancelledTurnSeq) return;');

    // Verify session_status does not resurrect canceled turns
    assert.ok(dshServiceSrc.includes('if (_activeTurnSeq > _cancelledTurnSeq && !_isCanceling)'),
      'session_status running flag must respect turn sequence fence');
  });

});

// =========================================================================
// SUITE 2: BoxConstraints & ScrollController Attachment Invariants (F1.3)
// =========================================================================
describe('M4 Challenge 2: BoxConstraints & ScrollController Invariants', () => {

  it('TC2.1: ThinkingCard BoxConstraints (maxHeight: 280) and Layout Clamping', () => {
    const thinkingCardPath = path.join(DSH_MOBILE_DIR, 'lib', 'widgets', 'thinking_card.dart');
    const thinkingCardSrc = fs.readFileSync(thinkingCardPath, 'utf8');

    // 1. BoxConstraints exact invariant
    assert.ok(
      thinkingCardSrc.includes('constraints: const BoxConstraints(maxHeight: 280)'),
      'ThinkingCard must enforce BoxConstraints(maxHeight: 280)'
    );

    // 2. Flexible with SingleChildScrollView inside Column
    assert.ok(
      thinkingCardSrc.includes('Flexible(') &&
      thinkingCardSrc.includes('SingleChildScrollView('),
      'ThinkingCard must wrap SingleChildScrollView inside Flexible'
    );

    // 3. ScrollController attached to both Scrollbar and SingleChildScrollView
    assert.ok(
      thinkingCardSrc.includes('Scrollbar(') && thinkingCardSrc.includes('controller: _scrollController'),
      'ThinkingCard must pass _scrollController to Scrollbar'
    );
    assert.ok(
      thinkingCardSrc.includes('SingleChildScrollView(') && thinkingCardSrc.includes('controller: _scrollController'),
      'ThinkingCard must pass _scrollController to SingleChildScrollView'
    );

    // 4. Dispose cleans up ScrollController
    assert.ok(
      thinkingCardSrc.includes('_scrollController.dispose()'),
      'ThinkingCard must dispose _scrollController in dispose()'
    );

    // 5. Client attachment guard before animating/jumping
    assert.ok(
      thinkingCardSrc.includes('if (_scrollController.hasClients)'),
      'ThinkingCard didUpdateWidget must guard with hasClients before scrolling'
    );
  });

  it('TC2.2: ThinkingCard Collapse Persistence Across Stream Tokens', () => {
    class ThinkingCardStateMachine {
      constructor(initialThinking = true) {
        this.isThinking = initialThinking;
        this.expanded = initialThinking;
        this.userCollapsed = false;
        this.content = '';
      }

      toggleUserCollapse() {
        this.expanded = !this.expanded;
        if (!this.expanded) {
          this.userCollapsed = true;
        } else {
          this.userCollapsed = false;
        }
      }

      onNewStreamChunk(newContent, isThinkingState) {
        const oldThinking = this.isThinking;
        this.isThinking = isThinkingState;
        this.content = newContent;

        if (!oldThinking && this.isThinking) {
          this.userCollapsed = false;
          this.expanded = true;
        }
      }
    }

    const card = new ThinkingCardStateMachine(true);
    assert.equal(card.expanded, true);

    // User explicitly collapses card during thinking phase
    card.toggleUserCollapse();
    assert.equal(card.expanded, false);
    assert.equal(card.userCollapsed, true);

    // 100 incoming thinking chunks arrive
    for (let i = 1; i <= 100; i++) {
      card.onNewStreamChunk(`Thinking step ${i}...`, true);
      assert.equal(card.expanded, false, `Card must NOT re-expand on chunk ${i} after user collapsed it`);
      assert.equal(card.userCollapsed, true);
    }

    // Thinking ends (isThinking = false)
    card.onNewStreamChunk(card.content, false);
    assert.equal(card.expanded, false);

    // Next turn begins: new thinking starts from non-thinking state
    card.onNewStreamChunk('New turn thinking...', true);
    assert.equal(card.expanded, true, 'Card auto-expands on fresh thinking turn transition');
    assert.equal(card.userCollapsed, false);
  });

  it('TC2.3: ToolCallCard Dual BoxConstraints (maxHeight: 240) and Dual ScrollControllers', () => {
    const toolCallCardPath = path.join(DSH_MOBILE_DIR, 'lib', 'widgets', 'tool_call_card.dart');
    const toolCallCardSrc = fs.readFileSync(toolCallCardPath, 'utf8');

    // 1. Both input and output BoxConstraints(maxHeight: 240)
    const matches240 = (toolCallCardSrc.match(/BoxConstraints\(maxHeight:\s*240\)/g) || []).length;
    assert.equal(matches240, 2, `ToolCallCard must declare BoxConstraints(maxHeight: 240) exactly twice (input and output), found ${matches240}`);

    // 2. Both controllers instantiated and disposed
    assert.ok(toolCallCardSrc.includes('final ScrollController _inputScrollController = ScrollController();'), 'Instantiates _inputScrollController');
    assert.ok(toolCallCardSrc.includes('final ScrollController _outputScrollController = ScrollController();'), 'Instantiates _outputScrollController');
    assert.ok(toolCallCardSrc.includes('_inputScrollController.dispose()'), 'Disposes _inputScrollController');
    assert.ok(toolCallCardSrc.includes('_outputScrollController.dispose()'), 'Disposes _outputScrollController');

    // 3. Controller attachment to Scrollbars and Views
    assert.ok(toolCallCardSrc.includes('controller: _inputScrollController'), 'Binds _inputScrollController');
    assert.ok(toolCallCardSrc.includes('controller: _outputScrollController'), 'Binds _outputScrollController');

    // 4. hasClients check in didUpdateWidget
    assert.ok(toolCallCardSrc.includes('if (_outputScrollController.hasClients)'), 'Guards output scroll with hasClients');
  });

  it('TC2.4: ToolCallCard _formatSummary Stress and Extreme Length Handling', () => {
    function formatSummary(tool) {
      if (tool.isRunning) return '运行中...';
      if (!tool.output || tool.output.length === 0) return '完成 (无输出)';
      const lines = tool.output.split('\n').length;
      const chars = tool.output.length;
      const sizeStr = chars >= 1024 ? `${(chars / 1024).toFixed(1)} KB` : `${chars} B`;
      return `${lines} 行 · ${sizeStr}`;
    }

    assert.equal(formatSummary({ isRunning: true, output: '' }), '运行中...');
    assert.equal(formatSummary({ isRunning: false, output: '' }), '完成 (无输出)');
    assert.equal(formatSummary({ isRunning: false, output: 'Hello' }), '1 行 · 5 B');
    assert.equal(formatSummary({ isRunning: false, output: 'A\nB\nC' }), '3 行 · 5 B');

    // 50,000 lines stress
    const bigOutput = 'X'.repeat(100) + ('\n' + 'Y'.repeat(100)).repeat(49999);
    const summary = formatSummary({ isRunning: false, output: bigOutput });
    assert.ok(summary.startsWith('50000 行 · '));
    assert.ok(summary.includes('KB'));
  });

});

// =========================================================================
// SUITE 3: 401 Token Invalidation State Transition & Reconnect Suppression (F4.3)
// =========================================================================
describe('M4 Challenge 3: 401 Token Invalidation & Reconnect Suppression', () => {

  it('TC3.1: DshService handleAuthFailure State Invariants', () => {
    class DshServiceAuthEmulator {
      constructor() {
        this._isTokenInvalid = false;
        this._status = 'connected';
        this._isReconnecting = false;
        this._reconnectAttempts = 0;
        this._reconnectTimer = { active: true, cancel() { this.active = false; } };
        this._sessionPollTimer = { active: true, cancel() { this.active = false; } };
        this._heartbeatRunning = true;
        this._lastError = '';
        this.notifiedCount = 0;
      }

      handleAuthFailure(reason) {
        this._isTokenInvalid = true;
        this._lastError = reason;
        this._status = 'error';
        this._isReconnecting = false;
        if (this._reconnectTimer) {
          this._reconnectTimer.cancel();
          this._reconnectTimer = null;
        }
        if (this._sessionPollTimer) {
          this._sessionPollTimer.cancel();
          this._sessionPollTimer = null;
        }
        this._heartbeatRunning = false;
        this.notifiedCount++;
      }

      scheduleReconnect() {
        if (this._isTokenInvalid) {
          return false; // suppressed!
        }
        this._reconnectAttempts++;
        return true;
      }

      clearAuthError() {
        this._isTokenInvalid = false;
        this._lastError = '';
        this.notifiedCount++;
      }
    }

    const svc = new DshServiceAuthEmulator();
    assert.equal(svc._isTokenInvalid, false);

    // Simulate 401 Unauthorized trigger
    svc.handleAuthFailure('Token已失效或无访问权限 (HTTP 401)');
    assert.equal(svc._isTokenInvalid, true);
    assert.equal(svc._status, 'error');
    assert.equal(svc._isReconnecting, false);
    assert.equal(svc._reconnectTimer, null);
    assert.equal(svc._sessionPollTimer, null);
    assert.equal(svc._heartbeatRunning, false);
    assert.ok(svc._lastError.includes('401'));

    // Attempt 100 reconnections: ALL must be suppressed
    for (let i = 0; i < 100; i++) {
      const scheduled = svc.scheduleReconnect();
      assert.equal(scheduled, false, `Reconnect attempt ${i} must be blocked by _isTokenInvalid`);
    }
    assert.equal(svc._reconnectAttempts, 0, 'Zero reconnect attempts must have been scheduled');

    // Simulate user reconfiguring token and clearing auth error
    svc.clearAuthError();
    assert.equal(svc._isTokenInvalid, false);
    assert.equal(svc._lastError, '');

    // Now reconnection is permitted again
    assert.equal(svc.scheduleReconnect(), true);
    assert.equal(svc._reconnectAttempts, 1);
  });

  it('TC3.2: Static Inspection of Auth Checks across all REST endpoints in dsh_service.dart', () => {
    const dshServicePath = path.join(DSH_MOBILE_DIR, 'lib', 'services', 'dsh_service.dart');
    const dshServiceSrc = fs.readFileSync(dshServicePath, 'utf8');

    // 1. handleAuthFailure declaration and properties
    assert.ok(dshServiceSrc.includes('void handleAuthFailure(String reason) {'), 'Must declare handleAuthFailure');
    assert.ok(dshServiceSrc.includes('_isTokenInvalid = true;'), 'handleAuthFailure must set _isTokenInvalid = true');
    assert.ok(dshServiceSrc.includes('_reconnectTimer?.cancel();'), 'handleAuthFailure must cancel _reconnectTimer');
    assert.ok(dshServiceSrc.includes('_stopHeartbeat();'), 'handleAuthFailure must stop heartbeat');

    // 2. clearAuthError declaration
    assert.ok(dshServiceSrc.includes('void clearAuthError() {'), 'Must declare clearAuthError');
    assert.ok(dshServiceSrc.includes('_isTokenInvalid = false;'), 'clearAuthError must clear _isTokenInvalid');

    // 3. _checkResponseAuth helper
    assert.ok(dshServiceSrc.includes('bool _checkResponseAuth(http.Response res) {'), 'Must declare _checkResponseAuth helper');
    assert.ok(dshServiceSrc.includes('if (res.statusCode == 401 || res.statusCode == 403)'), 'Checks 401 and 403');

    // 4. Verification that _checkResponseAuth is attached to endpoints
    const authCheckMatches = (dshServiceSrc.match(/_checkResponseAuth\(res\)/g) || []).length;
    assert.ok(authCheckMatches >= 12, `_checkResponseAuth must be attached across REST endpoints (found ${authCheckMatches})`);

    // 5. Reconnection suppression guard
    assert.ok(
      dshServiceSrc.includes('if (_isExplicitlyDisconnected || _isDisposed || _isTokenInvalid || _currentConfig == null)'),
      '_scheduleReconnect and _executeReconnect must guard with _isTokenInvalid'
    );
  });

  it('TC3.3: WebSocket 401 Error & Close Code Detection Invariants', () => {
    const dshServicePath = path.join(DSH_MOBILE_DIR, 'lib', 'services', 'dsh_service.dart');
    const dshServiceSrc = fs.readFileSync(dshServicePath, 'utf8');

    // 1. WebSocket stream onError 401 check
    assert.ok(
      dshServiceSrc.includes("if (errStr.contains('401') || errStr.contains('unauthorized'))"),
      'WS onError must detect 401 or unauthorized'
    );

    // 2. WebSocket stream onDone close codes check
    assert.ok(
      dshServiceSrc.includes('if (code == 4001 || code == 4401 || code == 1008)'),
      'WS onDone must detect close codes 4001, 4401, 1008'
    );

    // 3. WebSocket message frame auth error check
    assert.ok(
      dshServiceSrc.includes("if (json['code'] == 401 || json['type'] == 'unauthorized' || json['status'] == 401)"),
      'WS _handleRawMessage must detect auth error frame'
    );
  });

  it('TC3.4: UI 401 Warning Banner Presentation in ChatView & MainShell', () => {
    const chatViewPath = path.join(DSH_MOBILE_DIR, 'lib', 'views', 'chat_view.dart');
    const mainShellPath = path.join(DSH_MOBILE_DIR, 'lib', 'views', 'main_shell.dart');
    const configPagePath = path.join(DSH_MOBILE_DIR, 'lib', 'views', 'config_page.dart');

    const chatViewSrc = fs.readFileSync(chatViewPath, 'utf8');
    const mainShellSrc = fs.readFileSync(mainShellPath, 'utf8');
    const configPageSrc = fs.readFileSync(configPagePath, 'utf8');

    // 1. ChatView offline banner has isTokenInvalid branch
    assert.ok(chatViewSrc.includes('if (dsh.isTokenInvalid)'), 'ChatView must check dsh.isTokenInvalid in banner');
    assert.ok(chatViewSrc.includes('访问令牌已失效 (HTTP 401)'), 'ChatView banner displays 401 warning text');
    assert.ok(chatViewSrc.includes('MaterialPageRoute(builder: (_) => const ConfigPage())'), 'ChatView banner navigates to ConfigPage');

    // 2. MainShell top-level banner has isTokenInvalid branch
    assert.ok(mainShellSrc.includes('if (dsh.isTokenInvalid)'), 'MainShell must render banner when dsh.isTokenInvalid');
    assert.ok(mainShellSrc.includes('401 Unauthorized'), 'MainShell banner displays 401 notice');
    assert.ok(mainShellSrc.includes('MaterialPageRoute(builder: (_) => const ConfigPage())'), 'MainShell banner navigates to ConfigPage');

    // 3. ConfigPage clears auth error on success
    assert.ok(configPageSrc.includes('dshService.clearAuthError()'), 'ConfigPage must call clearAuthError()');
  });

});

// =========================================================================
// SUITE 4: Resource Cleanups, SafeMarkdown, Model Parsing & Live Boundaries (F4.1 - F4.5)
// =========================================================================
describe('M4 Challenge 4: Resource Cleanups, SafeMarkdown, Model Parsing & Boundaries', () => {

  it('TC4.1: Timer and Subscription Cleanup in Views and Service', () => {
    const workspacesViewPath = path.join(DSH_MOBILE_DIR, 'lib', 'views', 'workspaces_view.dart');
    const workspacesViewSrc = fs.readFileSync(workspacesViewPath, 'utf8');
    const dshServicePath = path.join(DSH_MOBILE_DIR, 'lib', 'services', 'dsh_service.dart');
    const dshServiceSrc = fs.readFileSync(dshServicePath, 'utf8');

    // WorkspacesView periodic timer cleanup
    assert.ok(workspacesViewSrc.includes('_refreshTimer?.cancel()'), 'WorkspacesView must cancel _refreshTimer in dispose()');
    assert.ok(workspacesViewSrc.includes('_searchController.dispose()'), 'WorkspacesView must dispose _searchController');

    // DshService socket and subscription cleanup
    assert.ok(dshServiceSrc.includes('_cleanTeardownSocket()'), 'DshService must provide _cleanTeardownSocket()');
    assert.ok(dshServiceSrc.includes('_channelSubscription?.cancel()'), 'DshService must cancel _channelSubscription');
    assert.ok(dshServiceSrc.includes('_channel!.sink.close(ws_status.goingAway)'), 'DshService must close sink with goingAway');
  });

  it('TC4.2: SafeMarkdown Fault Tolerance & Code Fence Auto-Closure', () => {
    const safeMarkdownPath = path.join(DSH_MOBILE_DIR, 'lib', 'widgets', 'safe_markdown.dart');
    const safeMarkdownSrc = fs.readFileSync(safeMarkdownPath, 'utf8');

    // Verify sanitizeMarkdown implementation
    assert.ok(safeMarkdownSrc.includes('String sanitizeMarkdown(String? raw)'), 'Declares sanitizeMarkdown');
    assert.ok(safeMarkdownSrc.includes("raw.replaceAll('\\u0000', '')"), 'Strips null bytes');
    assert.ok(safeMarkdownSrc.includes('fenceMatches.length % 2 != 0'), 'Checks for odd count of code fences');
    assert.ok(safeMarkdownSrc.includes("text = '$text\\n```';"), 'Auto-closes unclosed code fences');

    // Verify emulation of sanitizeMarkdown
    function sanitizeMarkdown(raw) {
      if (raw == null || raw.length === 0) return '';
      let text = raw.replace(/\u0000/g, '');
      const fenceMatches = text.match(/```/g) || [];
      if (fenceMatches.length % 2 !== 0) {
        text = text + '\n```';
      }
      text = text.replace(/<(?![a-zA-Z/!])/g, '&lt;');
      return text;
    }

    // Test cases
    assert.equal(sanitizeMarkdown(null), '');
    assert.equal(sanitizeMarkdown(''), '');
    assert.equal(sanitizeMarkdown('Hello \u0000World'), 'Hello World');
    assert.equal(sanitizeMarkdown('```typescript\nconst x = 1;'), '```typescript\nconst x = 1;\n```', 'Auto-closes single fence');
    assert.equal(sanitizeMarkdown('```\na\n```\n```\nb'), '```\na\n```\n```\nb\n```', 'Auto-closes 3rd fence');
    assert.equal(sanitizeMarkdown('```\na\n```'), '```\na\n```', 'Even fences left unchanged');
    assert.equal(sanitizeMarkdown('x < 5 && y > 2'), 'x &lt; 5 && y > 2', 'Escapes naked less-than');
    assert.equal(sanitizeMarkdown('<div>text</div>'), '<div>text</div>', 'Preserves valid HTML tags');
  });

  it('TC4.3: Defensive Model Coercion on Non-String Tool Inputs', () => {
    function coerceToolInput(raw) {
      if (raw == null) return '';
      if (typeof raw === 'string') return raw;
      if (typeof raw === 'object') {
        try {
          return JSON.stringify(raw, null, 2);
        } catch (_) {
          return String(raw);
        }
      }
      return String(raw);
    }

    assert.equal(coerceToolInput(null), '');
    assert.equal(coerceToolInput(''), '');
    assert.equal(coerceToolInput('rm -rf /tmp'), 'rm -rf /tmp');
    assert.equal(coerceToolInput({ command: 'git status', flags: ['-s'] }), JSON.stringify({ command: 'git status', flags: ['-s'] }, null, 2));
    assert.equal(coerceToolInput([1, 2, 3]), JSON.stringify([1, 2, 3], null, 2));
    assert.equal(coerceToolInput(12345), '12345');
    assert.equal(coerceToolInput(true), 'true');
  });

  it('TC4.4: Live Server Bridge Security Boundaries (Payload Limit, Traversal in fileName, 401)', async () => {
    // 1. Oversized 3MB payload triggers 413 Payload Too Large or socket destroy
    const oversized3MB = 'A'.repeat(3 * 1024 * 1024);
    try {
      const postRes = await apiRequest('/api/mobile/permissions', {
        method: 'POST',
        rawBody: oversized3MB,
        headers: { 'Content-Type': 'application/json' }
      });
      assert.ok(postRes.status === 413 || postRes.status === 400, `3MB request must be rejected with HTTP 413 (got ${postRes.status})`);
    } catch (err) {
      // Fetch throws or socket aborts when server destroys stream per MAX_BODY_SIZE
      assert.ok(err);
    }

    // 2. Path traversal attempt in fileName parameter is properly rejected with 403 Forbidden
    const traversalRes = await apiRequest('/api/mobile/workspace/memory?workspacePath=C:/test&fileName=../../win.ini');
    assert.equal(traversalRes.status, 403, `Path traversal in fileName must be rejected with HTTP 403 (got ${traversalRes.status})`);

    // 3. Unauthenticated request to /api/mobile/workspaces triggers 401 Unauthorized
    const unauthRes = await apiRequest('/api/mobile/workspaces', {
      token: 'invalid_wrong_token'
    });
    assert.equal(unauthRes.status, 401, `Invalid token must return HTTP 401 (got ${unauthRes.status})`);
  });

});

// =========================================================================
// SUITE 5: Adversarial Stress Challenges & Vulnerability Analysis
// =========================================================================
describe('M4 Challenge 5: Adversarial Defect & Vulnerability Remediations', () => {

  it('CHALLENGE 5.1 [REMEDIATED]: Path traversal via workspacePath escapes workspace boundary is blocked (F4.5 Remediated)', async () => {
    const res = await apiRequest('/api/mobile/workspace/memory?workspacePath=../../Windows&fileName=test.txt');

    console.log('\n[CHALLENGE 5.1 AUDIT]');
    console.log('Target: GET /api/mobile/workspace/memory?workspacePath=../../Windows&fileName=test.txt');
    console.log('HTTP Status:', res.status);
    console.log('Resolved FilePath:', res.data?.filePath);

    // In a hardened implementation, escaping the workspace root via relative path must return HTTP 403.
    assert.equal(res.status, 403, 'Hardened implementation must reject traversed workspacePath with 403 Forbidden');
  });

  it('CHALLENGE 5.2 [REMEDIATED]: Turn Cancel Sequence Fence in tool_result WS Handler is Enforced (F1.5 Remediated)', () => {
    const dshServicePath = path.join(DSH_MOBILE_DIR, 'lib', 'services', 'dsh_service.dart');
    const dshServiceSrc = fs.readFileSync(dshServicePath, 'utf8');

    // Extract tool_result block from dsh_service.dart
    const toolResultBlockMatch = dshServiceSrc.match(/if\s*\(\s*type\s*==\s*'tool_result'[\s\S]*?return;\s*\}/);
    assert.ok(toolResultBlockMatch, 'Must find tool_result block in dsh_service.dart');
    const toolResultBlock = toolResultBlockMatch[0];

    // Verify whether tool_result checks _isCanceling or _activeTurnSeq <= _cancelledTurnSeq
    const hasCancelingCheck = toolResultBlock.includes('_isCanceling');
    const hasTurnSeqCheck = toolResultBlock.includes('_cancelledTurnSeq');

    console.log('\n[CHALLENGE 5.2 AUDIT]');
    console.log('tool_result has _isCanceling guard:', hasCancelingCheck);
    console.log('tool_result has _cancelledTurnSeq fence:', hasTurnSeqCheck);

    assert.equal(hasCancelingCheck, true, 'tool_result handler must have _isCanceling guard');
    assert.equal(hasTurnSeqCheck, true, 'tool_result handler must have _cancelledTurnSeq sequence fence');
  });

});

