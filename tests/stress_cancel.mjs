import { apiRequest, createWsClient } from './e2e/helpers/client.js';
import assert from 'node:assert/strict';

async function runStressTests() {
  console.log('=== STARTING EMPIRICAL STRESS TESTS FOR M1 TURN CANCELLATION & STREAM STATES ===\n');

  const wsRes = await apiRequest('/api/mobile/workspaces');
  const targetWs = wsRes.data.workspaces[0];
  const workspaceId = targetWs.workspaceId;

  // -------------------------------------------------------------
  // Test 1: Active prompt submission and orphaned isRunning state
  // -------------------------------------------------------------
  console.log('--- TEST 1: Prompt Submission RPC Contract & Orphaned Stream State ---');
  {
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId }
    });
    const sId = sRes.data.sessionId;

    const wsClient = await createWsClient();
    await wsClient.waitForMessage(m => m.type === 'connected', 3000);
    wsClient.send({ type: 'subscribe_session', sessionId: sId });

    console.log(`[Test 1] Submitting prompt to ${sId}...`);
    const promptRes = await apiRequest('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: sId, text: 'Hello, what is 2+2?' }
    });

    console.log(`[Test 1] Prompt HTTP Status: ${promptRes.status}`);
    console.log(`[Test 1] Prompt Response:`, JSON.stringify(promptRes.data));
    assert.equal(promptRes.status, 200, 'Prompt submission should succeed with 200');

    // Wait to capture WebSocket running event
    await new Promise(r => setTimeout(r, 400));

    // Now cancel the active prompt turn
    console.log(`[Test 1] Cancelling active prompt turn for ${sId}...`);
    const cancelRes = await apiRequest('/api/mobile/sessions/cancel', {
      method: 'POST',
      body: { sessionId: sId }
    });
    console.log(`[Test 1] Cancel HTTP Status: ${cancelRes.status}`);
    assert.equal(cancelRes.status, 200, 'Cancel should return 200');

    // Poll until the terminal frame arrives instead of sampling after a fixed delay:
    // a fixed sleep can capture the intermediate isRunning:true frame from the prompt
    // broadcast and fail a correct implementation.
    const deadline = Date.now() + 3000;
    let lastStatus = null;
    while (Date.now() < deadline) {
      lastStatus = wsClient.messages
        .filter(m => m.sessionId === sId && m.type === 'session_status')
        .pop();
      if (lastStatus?.isRunning === false) break;
      await new Promise(r => setTimeout(r, 50));
    }
    const sessionMessages = wsClient.messages.filter(m => m.sessionId === sId);
    console.log(`[Test 1] WS Messages received for session:`, JSON.stringify(sessionMessages));

    const hasErrorEvent = sessionMessages.some(m => m.type === 'error');
    const hasDoneEvent = sessionMessages.some(m => m.type === 'done');

    console.log(`[Test 1] Last session_status isRunning:`, lastStatus?.isRunning);
    console.log(`[Test 1] Has error event broadcast:`, hasErrorEvent);
    console.log(`[Test 1] Has done event broadcast:`, hasDoneEvent);

    assert.equal(lastStatus?.isRunning, false, 'Final session status after cancel must be isRunning: false');
    assert.equal(hasDoneEvent, true, 'Cancellation must emit done event');
    console.log('✅ [Test 1 Passed]: Active turn cancellation transitions cleanly to isRunning: false with done event.\n');

    // Test 1B: Verify prompt error cleanup on invalid session
    console.log('--- TEST 1B: Prompt Error Cleanup on Failing Session ---');
    const errSessionId = 'invalid-session-' + Date.now();
    wsClient.send({ type: 'subscribe_session', sessionId: errSessionId });

    const errPromptRes = await apiRequest('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: errSessionId, text: 'Error prompt test' }
    });
    console.log(`[Test 1B] Failing prompt HTTP Status: ${errPromptRes.status}`);
    assert.equal(errPromptRes.status, 500, 'Failing prompt returns 500');

    // Poll until the terminal isRunning:false frame arrives (see Test 1 note).
    const errDeadline = Date.now() + 3000;
    let errLastStatus = null;
    while (Date.now() < errDeadline) {
      errLastStatus = wsClient.messages
        .filter(m => m.sessionId === errSessionId && m.type === 'session_status')
        .pop();
      if (errLastStatus?.isRunning === false) break;
      await new Promise(r => setTimeout(r, 50));
    }
    const errMessages = wsClient.messages.filter(m => m.sessionId === errSessionId);
    const errHasError = errMessages.some(m => m.type === 'error');
    const errHasDone = errMessages.some(m => m.type === 'done');

    console.log(`[Test 1B] Last status isRunning:`, errLastStatus?.isRunning);
    console.log(`[Test 1B] Has error broadcast:`, errHasError);
    console.log(`[Test 1B] Has done broadcast:`, errHasDone);
    assert.equal(errLastStatus?.isRunning, false, 'Error path must broadcast isRunning: false');
    assert.equal(errHasError, true, 'Error path must broadcast error event');
    assert.equal(errHasDone, true, 'Error path must broadcast done event');
    console.log('✅ [Test 1B Passed]: Prompt error path cleanly broadcasts isRunning: false and error event.\n');

    wsClient.close();
    await apiRequest('/api/mobile/sessions/delete', {
      method: 'POST',
      body: { sessionId: sId, workspaceId }
    });
  }

  // -------------------------------------------------------------
  // Test 2: Rapid prompt-then-cancel race condition (0ms - 50ms)
  // -------------------------------------------------------------
  console.log('--- TEST 2: Rapid Prompt-Then-Cancel Race Condition Stress (10 cycles) ---');
  let raceInversions = 0;
  for (let i = 0; i < 10; i++) {
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId }
    });
    const sId = sRes.data.sessionId;

    const wsClient = await createWsClient();
    await wsClient.waitForMessage(m => m.type === 'connected', 3000);
    wsClient.send({ type: 'subscribe_session', sessionId: sId });

    // Send prompt and cancel immediately in parallel
    const promptPromise = apiRequest('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: sId, text: `Stress prompt ${i}` }
    });
    // Small stagger between 0ms and 30ms
    if (i % 2 === 1) await new Promise(r => setTimeout(r, 10));

    const cancelPromise = apiRequest('/api/mobile/sessions/cancel', {
      method: 'POST',
      body: { sessionId: sId }
    });

    const [pRes, cRes] = await Promise.all([promptPromise, cancelPromise]);

    // Give time for socket events to settle
    await new Promise(r => setTimeout(r, 400));

    const statusEvents = wsClient.messages
      .filter(m => m.sessionId === sId && m.type === 'session_status')
      .map(m => m.isRunning);

    const finalStatus = statusEvents[statusEvents.length - 1];
    console.log(`[Cycle ${i + 1}] Prompt: ${pRes.status}, Cancel: ${cRes.status}, Status history: [${statusEvents.join(' -> ')}], Final isRunning: ${finalStatus}`);

    if (finalStatus === true) {
      raceInversions++;
      console.log(`  -> ⚠️ Cycle ${i + 1} resulted in ORPHANED isRunning: true due to cancel being processed before prompt status!`);
    }

    wsClient.close();
    await apiRequest('/api/mobile/sessions/delete', {
      method: 'POST',
      body: { sessionId: sId, workspaceId }
    });
  }
  console.log(`[Test 2 Result] Total race condition inversions: ${raceInversions}/10\n`);
  assert.equal(raceInversions, 0, 'Total race condition inversions must be 0');

  // -------------------------------------------------------------
  // Test 3: Multiple rapid sequential cancellations (Idempotency stress)
  // -------------------------------------------------------------
  console.log('--- TEST 3: Cancellation Idempotency & Flood Stress ---');
  {
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId }
    });
    const sId = sRes.data.sessionId;

    // Send 20 concurrent cancel requests
    const cancelPromises = Array.from({ length: 20 }, (_, idx) =>
      apiRequest('/api/mobile/sessions/cancel', {
        method: 'POST',
        body: { sessionId: sId }
      })
    );

    const results = await Promise.all(cancelPromises);
    const all200 = results.every(r => r.status === 200 && r.data.ok === true);
    console.log(`[Test 3] 20 concurrent cancellations: all HTTP 200: ${all200}`);
    assert.equal(all200, true, 'All 20 concurrent cancellations must return 200');

    await apiRequest('/api/mobile/sessions/delete', {
      method: 'POST',
      body: { sessionId: sId, workspaceId }
    });
  }

  console.log('\n=== EMPIRICAL STRESS TESTS COMPLETE ===');
}

runStressTests().catch(err => {
  console.error('Fatal stress test failure:', err);
  process.exit(1);
});
