/**
 * 跨会话搜索：标题 → 首条 prompt → 正文（turnOutline）。
 *
 * 这组用例守的是 2026-11-18 用户实测反馈的那个缺陷：**搜中文有结果、搜英文
 * 没有**。根因是网关只匹配 `title` 与 `firstPrompt`，而英文词几乎只出现在正文
 * 里。所以这里第一要务是钉住「正文也能命中」，其次才是排序、截断与预算。
 *
 * 纯函数测试：不启服务、不连引擎。
 */
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  makeSearchSnippet,
  findTurnOutlineMatch,
  searchSessionsInWorkspaces
} from '../../dsh-server-plugin/lib/features.mjs';

/** projcache `record.rows` 的最小形状（只有 turnOutline 与本函数有关）。 */
function rowsWith(turns) {
  return { turnOutline: { val: { turns } } };
}

function session(id, extra = {}) {
  return {
    sessionId: id,
    title: '',
    firstPrompt: '',
    lastPromptAt: 0,
    archived: false,
    ...extra
  };
}

function workspace(id, sessions) {
  return { workspaceId: id, title: `${id}-title`, sessions };
}

test('makeSearchSnippet：命中点居中，两端按需加省略号', () => {
  const text = 'aaaa bbbb NEEDLE cccc dddd';
  const at = text.indexOf('NEEDLE');
  const out = makeSearchSnippet(text, at, 'NEEDLE'.length, 5);
  assert.equal(out, '…bbbb NEEDLE cccc…');
});

test('makeSearchSnippet：短文本不加省略号，且折叠换行', () => {
  assert.equal(makeSearchSnippet('ab\ncd', 0, 2, 30), 'ab cd');
});

test('makeSearchSnippet：非法下标不抛，按开头截断', () => {
  assert.equal(makeSearchSnippet('hello', -5, 0, 2), 'he…');
  assert.equal(makeSearchSnippet(null, 0, 0), '');
});

test('findTurnOutlineMatch：从最新一轮往前找，返回轮次与字段', () => {
  const rows = rowsWith([
    { turn: 1, prompt: '早先的 English word 在这里', response: '好' },
    { turn: 2, prompt: '后来的提问', response: '这里也有 english word' }
  ]);
  const hit = findTurnOutlineMatch(rows, 'english word');
  assert.ok(hit);
  // 最新一轮优先 —— 用户找的通常是刚发生的事。
  assert.equal(hit.turn, 2);
  assert.equal(hit.field, 'response');
});

test('findTurnOutlineMatch：prompt 与 response 同一轮时 prompt 优先', () => {
  const rows = rowsWith([{ turn: 3, prompt: 'needle 在 prompt', response: 'needle 也在 response' }]);
  const hit = findTurnOutlineMatch(rows, 'needle');
  assert.equal(hit.field, 'prompt');
});

test('findTurnOutlineMatch：没有投影 / 没命中 / 关键词为空都返回 null', () => {
  assert.equal(findTurnOutlineMatch(null, 'x'), null);
  assert.equal(findTurnOutlineMatch({}, 'x'), null);
  assert.equal(findTurnOutlineMatch(rowsWith([]), 'x'), null);
  assert.equal(findTurnOutlineMatch(rowsWith([{ turn: 1, prompt: 'abc' }]), 'zzz'), null);
  assert.equal(findTurnOutlineMatch(rowsWith([{ turn: 1, prompt: 'abc' }]), ''), null);
});

test('搜索：英文只在正文里也能命中（本次缺陷的主用例）', () => {
  const rows = new Map([
    [
      's1',
      rowsWith([
        { turn: 1, prompt: '帮我把顶栏改一下', response: '改完了，AppBar 的高度从 90dp 降到 53dp' }
      ])
    ]
  ]);
  const { results, partial } = searchSessionsInWorkspaces({
    query: 'appbar', // 小写查询命中大写正文：大小写不敏感
    workspaces: [workspace('w1', [session('s1', { title: '顶栏改造', lastPromptAt: 100 })])],
    readProjectionRows: (id) => rows.get(id) || null
  });

  assert.equal(partial, false);
  assert.equal(results.length, 1);
  assert.equal(results[0].matchField, 'body');
  assert.equal(results[0].turn, 1);
  assert.match(results[0].snippet, /AppBar/);
});

test('搜索：标题命中优先于正文，且不因正文没命中而漏掉', () => {
  const { results } = searchSessionsInWorkspaces({
    query: '顶栏',
    workspaces: [
      workspace('w1', [
        session('s1', { title: '顶栏改造', lastPromptAt: 10 }),
        session('s2', { title: '别的会话', firstPrompt: '顶栏那个问题', lastPromptAt: 20 })
      ])
    ],
    readProjectionRows: () => null
  });

  assert.equal(results.length, 2);
  // 按 lastPromptAt 倒序：最近的先出现。
  assert.equal(results[0].sessionId, 's2');
  assert.equal(results[0].matchField, 'prompt');
  assert.match(results[0].snippet, /顶栏/);
  assert.equal(results[1].matchField, 'title');
});

test('搜索：读投影抛异常只跳过该会话，不影响整次搜索', () => {
  const { results } = searchSessionsInWorkspaces({
    query: 'needle',
    workspaces: [
      workspace('w1', [
        session('broken', { title: '' }),
        session('s2', { title: 'needle 在这里' })
      ])
    ],
    readProjectionRows: (id) => {
      if (id === 'broken') throw new Error('half-written file');
      return null;
    }
  });

  assert.equal(results.length, 1);
  assert.equal(results[0].sessionId, 's2');
});

test('搜索：空查询返回空结果，不是全部会话', () => {
  const { results, scanned } = searchSessionsInWorkspaces({
    query: '   ',
    workspaces: [workspace('w1', [session('s1', { title: 'x' })])],
    readProjectionRows: () => null
  });
  assert.deepEqual(results, []);
  assert.equal(scanned, 0);
});

test('搜索：结果数受 max 限制', () => {
  const sessions = Array.from({ length: 8 }, (_, i) =>
    session(`s${i}`, { title: 'common', lastPromptAt: i })
  );
  const { results } = searchSessionsInWorkspaces({
    query: 'common',
    workspaces: [workspace('w1', sessions)],
    readProjectionRows: () => null,
    max: 3
  });
  assert.equal(results.length, 3);
  // 倒序取前三条 → 最新的三条。
  assert.deepEqual(
    results.map((r) => r.sessionId),
    ['s7', 's6', 's5']
  );
});

test('搜索：扫描预算用完时如实标 partial，而不是假装没命中', () => {
  const sessions = Array.from({ length: 10 }, (_, i) => session(`s${i}`, { title: '' }));
  const { results, scanned, partial } = searchSessionsInWorkspaces({
    query: 'needle',
    workspaces: [workspace('w1', sessions)],
    readProjectionRows: () => null,
    maxScan: 3
  });
  assert.equal(partial, true);
  assert.equal(scanned, 3);
  assert.deepEqual(results, []);
});
