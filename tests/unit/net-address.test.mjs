/**
 * 局域网地址判定（[fix 2026-10-21]）。
 *
 * 钉的是一个真机踩到的坑：`os.networkInterfaces()` 里"第一个非 internal IPv4"
 * 常常是虚拟网卡，不是手机能连的那块。实测这台机器：
 *
 *   172.20.128.1  vEthernet (WSL (Hyper-V firewall))
 *   10.49.80.16   以太网                                  ← 真正能连的
 *
 * 而网关回报的 localUrl 是 http://172.19.0.1:3088（Clash TUN）。手机扫到这个
 * 地址永远连不上，界面上却看不出任何异常 —— 所以顺序判定必须被测试钉住。
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

const { lanCandidates, primaryLanAddress, isVirtualOrUseless } = await import(
  '../../dsh-server-plugin/lib/net-address.mjs'
);

function ifaces(spec) {
  // spec: { '接口名': [['192.168.1.5', false], ...] }
  const out = {};
  for (const [name, list] of Object.entries(spec)) {
    out[name] = list.map(([address, internal]) => ({
      address,
      internal: internal === true,
      family: 'IPv4',
      netmask: '255.255.255.0',
      mac: '00:00:00:00:00:00'
    }));
  }
  return out;
}

describe('lan address picking', () => {
  it('真机形态：虚拟网卡排在前面，仍要挑出真实网卡', () => {
    const nets = ifaces({
      'vEthernet (WSL (Hyper-V firewall))': [['172.20.128.1', false]],
      '以太网': [['10.49.80.16', false]]
    });
    // Object.entries 的顺序就是 os.networkInterfaces() 的顺序，虚拟网卡在前
    assert.equal(Object.keys(nets)[0], 'vEthernet (WSL (Hyper-V firewall))');
    assert.equal(primaryLanAddress(nets), '10.49.80.16');
  });

  it('Clash TUN 的 172.19.0.1 不能当首选', () => {
    const nets = ifaces({
      'Clash': [['172.19.0.1', false]],
      '以太网': [['192.168.1.20', false]]
    });
    assert.equal(primaryLanAddress(nets), '192.168.1.20');
  });

  it('只有 TUN 时才退而求其次（有总比没有好）', () => {
    const nets = ifaces({ Tailscale: [['100.64.0.5', false]] });
    // 100.64/10 是运营商 NAT 段，不是私有段但也不是虚拟名称以外的首选
    assert.equal(lanCandidates(nets).length, 1);
    assert.equal(primaryLanAddress(nets), '100.64.0.5');
  });

  it('192.168 优先于 10 段（家用/办公最常见）', () => {
    const nets = ifaces({
      'Ethernet 2': [['10.1.2.3', false]],
      'Wi-Fi': [['192.168.31.7', false]]
    });
    assert.equal(primaryLanAddress(nets), '192.168.31.7');
  });

  it('APIPA（169.254，没拿到 DHCP）排到最后', () => {
    const nets = ifaces({
      '以太网': [['169.254.10.10', false], ['192.168.1.5', false]]
    });
    assert.equal(primaryLanAddress(nets), '192.168.1.5');
  });

  it('忽略回环与 IPv6', () => {
    const nets = ifaces({ 'Loopback': [['127.0.0.1', true]], '以太网': [['10.0.0.8', false]] });
    assert.equal(primaryLanAddress(nets), '10.0.0.8');
  });

  it('一个都没有时返回空串（调用方必须处理），不编一个地址出来', () => {
    assert.equal(primaryLanAddress({}), '');
    assert.equal(primaryLanAddress(ifaces({ 'Loopback': [['127.0.0.1', true]] })), '');
  });

  it('isVirtualOrUseless 对 TUN / WSL / APIPA 判真', () => {
    assert.equal(isVirtualOrUseless('172.19.0.1', 'Clash'), true);
    assert.equal(isVirtualOrUseless('172.20.128.1', 'vEthernet (WSL)'), true);
    assert.equal(isVirtualOrUseless('', '以太网'), true);
    assert.equal(isVirtualOrUseless('169.254.3.4', '以太网'), true);
    assert.equal(isVirtualOrUseless('192.168.1.20', '以太网'), false);
  });
});
