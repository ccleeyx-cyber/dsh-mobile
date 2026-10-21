// dsh-server-plugin 局域网地址判定
//
// ## 为什么需要这个模块
//
// 网关要给手机一个"能连上的地址"，而 `os.networkInterfaces()` 里**第一个**非
// internal 的 IPv4 经常不是它：
//
// 真机实测（2026-10-21）：真实网卡是 `10.49.80.16（以太网）`，但按"第一个"取值
// 拿到的是 `172.19.0.1`（Clash TUN），过一会儿又变成 `172.20.128.1`（WSL 虚拟
// 交换机）。手机扫到那个地址永远连不上，而且用户完全看不出是地址挑错了。
//
// 所以这里做两件事：
//   1. 把明显不是"手机能连的"接口剔掉（虚拟交换机 / TUN / 容器 / VPN 客户端）；
//   2. 在多块真实网卡之间排序（192.168 > 10 > 172.16-31，以太网/WLAN 优先）。
//
// 刻意不做 ARP/默认路由探测：那需要平台相关的命令调用，而出错时的表现（挑错
// 网卡）和这里一样，但代价大得多。名称 + 网段排序已经能覆盖本机的真实形态。

import os from 'node:os';

/** 明显是虚拟/隧道/容器接口的名称特征（Windows 与 Linux/macOS 都常见）。 */
const VIRTUAL_NAME = /vEthernet|Hyper-V|WSL|VirtualBox|VMware|docker|br-|veth|tun|tap|utun|Tailscale|ZeroTier|WireGuard|Clash|Mihomo|sing-box|loopback|Loopback|Npcap|Bluetooth/i;

/** 真实物理网卡的常见名称（加分项，不要求匹配）。 */
const PHYSICAL_NAME = /^(以太网|无线网络连接|WLAN|Wi-?Fi|Ethernet|eth\d|en\d|wlan\d|wlp)/i;

function scoreOf(name, address) {
  let score = 0;
  if (VIRTUAL_NAME.test(name)) score -= 1000;       // 虚拟接口基本判死
  if (PHYSICAL_NAME.test(name)) score += 100;
  if (address.startsWith('192.168.')) score += 60;  // 家用/办公最常见
  else if (address.startsWith('10.')) score += 50;
  else if (/^172\.(1[6-9]|2\d|3[01])\./.test(address)) score += 10; // 常被容器/TUN 占用
  else score += 5;
  if (address.startsWith('169.254.')) score -= 500; // APIPA：没拿到 DHCP，连不通
  return score;
}

/**
 * 所有可尝试的局域网 IPv4，按"最可能是手机能连的"排序。
 *
 * @returns {{address: string, name: string, score: number}[]}
 */
export function lanCandidates(interfaces = os.networkInterfaces()) {
  const out = [];
  for (const [name, list] of Object.entries(interfaces || {})) {
    for (const ni of list || []) {
      if (!ni || ni.family !== 'IPv4' || ni.internal) continue;
      out.push({ address: ni.address, name, score: scoreOf(name, ni.address) });
    }
  }
  return out.sort((a, b) => b.score - a.score);
}

/** 最可能被手机连到的那个地址；一个都没有时返回 ''（调用方必须处理空串）。 */
export function primaryLanAddress(interfaces = os.networkInterfaces()) {
  const best = lanCandidates(interfaces)[0];
  return best ? best.address : '';
}

/** 是否是"明显不该对外宣称"的地址（虚拟网卡 / APIPA）。 */
export function isVirtualOrUseless(address, name = '') {
  if (!address) return true;
  if (address.startsWith('169.254.')) return true;
  return VIRTUAL_NAME.test(name);
}
