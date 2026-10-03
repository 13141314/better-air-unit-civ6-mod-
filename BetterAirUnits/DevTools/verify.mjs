#!/usr/bin/env node
/* BetterAirUnits 交付后自检 —— 每次改完跑一次，游戏重启后再跑一次。
 * 用法: node DevTools/verify.mjs
 * 检查的是「引擎实际加载的结果」，不是「文件写了没写」。
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const SRC = path.resolve(import.meta.dirname, '..');
const INSTALLED = "C:\\Users\\丁钰霖\\Documents\\My Games\\Sid Meier's Civilization VI\\Mods\\BetterAirUnits";
const LOGDIR = "C:\\Users\\丁钰霖\\AppData\\Local\\Firaxis Games\\Sid Meier's Civilization VI\\Logs";
const CACHE = "C:\\Users\\丁钰霖\\AppData\\Local\\Firaxis Games\\Sid Meier's Civilization VI\\Cache\\DebugGameplay.sqlite";
const MOD_DIRS = ['F:\\SteamLibrary\\steamapps\\workshop\\content\\289070', INSTALLED.replace(/\\BetterAirUnits$/, '')];

let fail = 0;
const ok = m => console.log('  [OK]   ' + m);
const bad = m => { fail++; console.log('  [FAIL] ' + m); };
const info = m => console.log('  [..]   ' + m);
const readMaybe = p => { try { return fs.readFileSync(p, 'utf8'); } catch { return null; } };
function readLog(name) {
  const p = path.join(LOGDIR, name);
  if (!fs.existsSync(p)) return null;
  const buf = fs.readFileSync(p);
  return buf[0] === 0xFF && buf[1] === 0xFE ? buf.subarray(2).toString('utf16le') : buf.toString('utf8');
}
function blocksOf(xml, tag) {
  const out = [], re = new RegExp('<' + tag + '[^>]*>([\\s\\S]*?)</' + tag + '>', 'g');
  let m; while ((m = re.exec(xml))) out.push(m[1]);
  return out;
}

console.log('\n1) modinfo 组件引用 vs <Files>（集合校验，不用 includes 短路）');
const mi = readMaybe(path.join(SRC, 'BetterAirUnits.modinfo'));
if (!mi) bad('modinfo 读不到');
else {
  const filesDecl = [...blocksOf(mi, 'Files').join('\n').matchAll(/<File>([^<]+)<\/File>/g)].map(x => x[1].trim());
  const actions = blocksOf(mi, 'InGameActions').join('\n');
  const comps = [...actions.matchAll(/<(\w+)\s+id="([^"]*)"[\s\S]*?<\/\1>/g)].map(m => ({
    type: m[1], id: m[2],
    order: Number((m[0].match(/<LoadOrder>(\d+)<\/LoadOrder>/) || [])[1] ?? -1),
    refs: [...m[0].matchAll(/<(?:File|LuaReplace)>([^<]+)<\/(?:File|LuaReplace)>/g)].map(x => x[1].trim()),
  }));
  const refs = [...new Set(comps.flatMap(c => c.refs))];
  const missing = refs.filter(p => !filesDecl.includes(p));
  missing.length ? bad('组件引用没进 <Files>，引擎会静默剔除这个引用: ' + missing.join(', ')) : ok(refs.length + ' 个组件引用全部在 <Files> 中');
  const ghost = filesDecl.filter(p => !fs.existsSync(path.join(SRC, p.replace(/\//g, '\\'))));
  ghost.length ? bad('<Files> 声明了磁盘上不存在的文件: ' + ghost.join(', ')) : ok('<Files> ' + filesDecl.length + ' 项都在磁盘上');
  const dup = comps.flatMap(c => c.refs.filter((p, i) => c.refs.indexOf(p) !== i).map(p => c.id + ' -> ' + p));
  dup.length ? bad('组件内重复引用（插入脚本不幂等）: ' + dup.join(', ')) : ok('组件内无重复引用');
  const unref = filesDecl.filter(p => !refs.includes(p));
  if (unref.length) info('声明了但没被组件引用（可能忘加组件）: ' + unref.join(', '));

  console.log('\n2) UpdateDatabase LoadOrder 竞争（最后加载的人说话）');
  const orders = [];
  const walk = (d, depth) => {
    if (depth > 4) return;
    let ents; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) { walk(p, depth + 1); continue; }
      if (!/\.modinfo$/i.test(e.name)) continue;
      const x = readMaybe(p) || '';
      for (const m of x.matchAll(/<UpdateDatabase\s+id="([^"]*)"[\s\S]*?<\/UpdateDatabase>/g))
        orders.push({ order: Number((m[0].match(/<LoadOrder>(\d+)<\/LoadOrder>/) || [])[1] ?? -1), id: m[1], where: p });
    }
  };
  for (const r of MOD_DIRS) walk(r, 0);
  orders.sort((a, b) => a.order - b.order);
  const mine = orders.filter(o => /BetterAirUnits/i.test(o.id));
  const others = orders.filter(o => !/BetterAirUnits/i.test(o.id));
  const maxOther = others.length ? others[others.length - 1] : null;
  const myMax = mine.length ? Math.max(...mine.map(o => o.order)) : -1;
  info('其他模组最大 UpdateDatabase LoadOrder = ' + (maxOther ? maxOther.order + ' (' + maxOther.id + ')' : '无'));
  info('我们的最大 LoadOrder = ' + myMax);
  if (maxOther && myMax <= maxOther.order) bad('数据补丁不是最后加载，Units.Range 可能被别的模组覆写');
  else ok('我们的数据补丁最后加载');

  console.log('\n3) 谁在改 Units.Range（潜在覆写者）');
  const conflict = [];
  const scan = (d, depth) => {
    if (depth > 5) return;
    let ents; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) { scan(p, depth + 1); continue; }
      if (!/\.(sql|xml)$/i.test(e.name)) continue;
      const t = readMaybe(p); if (!t || t.length > 3e6) continue;
      for (const stmt of t.replace(/\r/g, '').split(';')) {
        const clean = stmt.split('\n').filter(l => !/^\s*--/.test(l)).join('\n');
        if (/update\s+Units\b/i.test(clean) && /\bRange\s*=/i.test(clean))
          conflict.push(p.replace(/^.*(289070\\|Mods\\)/, '') + ' :: ' + clean.trim().replace(/\s+/g, ' ').slice(0, 120));
      }
    }
  };
  for (const r of MOD_DIRS) scan(r, 0);
  conflict.slice(0, 10).forEach(c => console.log('         ' + c));
}

console.log('\n4) 桌面源码 == 安装目录');
const h = b => crypto.createHash('sha256').update(b).digest('hex').slice(0, 12);
const rels = ['BetterAirUnits.modinfo', 'Data/BetterAirUnits.xml', 'Data/BetterAirUnitsPatch.sql', 'Text/BetterAirUnits_Text.xml',
  'Scripts/BetterAirUnits.lua', 'UI/BetterAirUnitsUI.lua', 'UI/BetterAirUnitsUI.xml', 'UI/BetterAirUnitsUnitPanel.lua',
  'UI/BetterAirUnitsWorldInput.lua', 'UI/BetterAirUnitsDealView.lua', 'README.md'];
let diff = 0;
for (const f of rels) {
  const a = readMaybe(path.join(SRC, f.replace(/\//g, '\\')));
  const b = readMaybe(path.join(INSTALLED, f.replace(/\//g, '\\')));
  if (a === null || b === null) { bad('缺失: ' + f); diff++; }
  else if (h(Buffer.from(a)) !== h(Buffer.from(b))) { bad('内容不一致: ' + f); diff++; }
}
if (!diff) ok('三处清单 ' + rels.length + ' 文件全部一致（安装副本 = 源码）');

console.log('\n5) 上一局引擎实际加载了什么');
const modding = readLog('Modding.log');
if (!modding) info('没有 Modding.log');
else {
  const L = modding.split(/\r?\n/);
  const pass = L.filter(l => /Applying Component - BetterAirUnits/i.test(l)).length;
  pass ? ok('游戏段应用了 ' + pass + ' 个我们的组件') : bad('游戏段没应用我们的组件（模组没启用/读旧档）');
  L.some(l => /UpdateDatabase - Loading Data\/BetterAirUnitsPatch\.sql/.test(l))
    ? ok('Data/BetterAirUnitsPatch.sql 被引擎加载了') : bad('Data/BetterAirUnitsPatch.sql 未被加载（<Files> 漏了？还没重启？）');
  // 只在"最后一个游戏段"里比较：NewAction 是 ModBuddy 默认组件名，很多模组都叫这个，不能按名字比
  const passStart = lines => { let s = -1; lines.forEach((l, i) => { if (/Target in-game actions/.test(l)) s = i; }); return s; };
  const L2 = modding.split(/\r?\n/);
  const start = passStart(L2);
  let mineIdx = -1; const after = [];
  L2.forEach((l, i) => {
    if (i <= start) return;
    if (/Applying Component - BetterAirUnits_AAPatch \(UpdateDatabase\)/.test(l)) { mineIdx = i; after.length = 0; return; }
    const m = l.match(/Applying Component - (\S+) \(UpdateDatabase\)/);
    if (m && mineIdx > 0 && i > mineIdx) after.push(m[1]);
  });
  if (mineIdx < 0) info('最后一个游戏段里没有找到 BetterAirUnits_AAPatch（重启后再跑）');
  else if (after.length) info('我们之后还有 ' + after.length + ' 个 UpdateDatabase 组件在跑：' + [...new Set(after)].slice(0, 8).join(', ') + ' —— 以运行库实测值为准');
  else ok('我们的 AAPatch 是本局最后一个 UpdateDatabase 组件');
}
const lua = readLog('Lua.log');
if (lua) {
  const markers = ['[BetterAirUnits] loaded', 'rent section loaded', 'entry running', 'rent hooks installed'];
  const hit = markers.filter(m => lua.includes(m));
  hit.length ? ok('Lua 标记: ' + hit.join(' / ')) : bad('Lua.log 没有我们的加载标记 —— Lua 根本没跑');
  info('anchor guarded 次数 = ' + (lua.match(/anchor guarded/g) || []).length + '（和平期不该有）');
  info('rent relay 次数 = ' + (lua.match(/rent relay/g) || []).length);
} else info('没有 Lua.log');

try {
  const { DatabaseSync } = await import('node:sqlite');
  const st = fs.statSync(CACHE);
  const db = new DatabaseSync(CACHE, { readOnly: true });
  const want = { UNIT_ANTIAIR_GUN: 2, UNIT_MOBILE_SAM: 3 };
  for (const r of db.prepare("SELECT UnitType, Range FROM Units WHERE UnitType IN ('UNIT_ANTIAIR_GUN','UNIT_MOBILE_SAM')").all())
    (r.Range === want[r.UnitType] ? ok : bad)(r.UnitType + ' 运行时 Range=' + r.Range + '（期望 ' + want[r.UnitType] + '）');
  db.close();
  info('缓存库时间戳 ' + st.mtime.toISOString() + '；若早于 modinfo 修改时间 = 这局还没用新配置');
} catch (e) { info('读不到运行库: ' + e.message.slice(0, 60)); }

console.log('\n==== ' + (fail ? fail + ' 项 FAIL，别急着让玩家测' : '全部通过') + ' ====');
process.exitCode = fail ? 1 : 0;
