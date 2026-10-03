# Better Air Units - 移动力制飞机

一个基本不依赖 DLL 的文明 6 模组：核心逻辑是 Lua 脚本，只额外给飞机加了一个隐藏的“移动后可攻击”能力作为保险。

## 效果

- 战斗机 / 轰炸机“改变基地”（部署）不再固定消耗整个回合。
- 部署按距离消耗移动力：飞 1 格扣 1 点移动力，剩余移动力大于 0 时仍可继续空袭。
- 飞满全距离（例如战斗机飞满 8 格）则和原版一样结束回合，不能空袭。
- 剩余移动力允许时，同一回合内也可以多次部署。
- 空袭也会消耗移动力，消耗量 = 最大移动力 × 距离 × min(1, 防守方战力 / 攻击方战力)。
  例如 100 战力战斗机打 20 战力勇士、距离 1 格：8 × 1 × 0.2 = 1.6。
- 战力使用战斗结算时的实际值（含地形、晋升、夹击等加成）；小数余额会累积在单位上，
  攒够整点才真正扣移动力，避免“1.6 点”被引擎直接截断。
- 可以飞进战争迷雾和敌方领土：REBASE 界面会高亮移动力范围内的所有格子；
  引擎不允许的目标（迷雾/敌方领土）会走“自由飞行”，直接把飞机传过去并按距离扣移动力。
- **主动截击（新增）**：具备防空能力的陆/海军单位（防空炮、机动防空、直升机、
  驱逐舰、战列舰、导弹巡洋舰等，即原版 CanTargetAir / AntiAirCombat 的那批）
  现在能**主动攻击射程内的高亮敌方飞机**：
  - 点“攻击”按钮进入瞄准模式（高亮射程内敌机），或右击敌方飞机直接开火；
  - 伤害按原版战斗公式的期望值结算：30 × exp((防空战力 − 飞机战力) / 25)，
    减员（伤害≥50）时战力打 65 折；防空炮/机动防空用 AntiAirCombat(90/100)，
    直升机用战力 86；导弹巡洋舰 110；
  - 射程：防空炮 2 格、防空导弹车（机动防空）3 格、战列舰/导弹巡洋舰 3 格，
    其余防空单位（直升机/驱逐舰等）1 格；
  - 命中 +4 经验，击落共 +10 经验；开火消耗本回合行动；
  - 战列舰、导弹巡洋舰等原有对海/对陆远程攻击**不受影响**（两类目标并存）。
  - 已知限制：AI 暂不会主动使用；不掷随机（多人安全）所以伤害是固定期望值。
- **防空单位成军（新增）**：防空炮/机动防空等防空单位现在也能像空军一样合成：
  2 门同型 → 军团（+7 战力），军团 +1 同型 → 军队（共 +15 战力）——加成直接体现在
  单位面板的“防空力量”数值上（如机动防空军团显示 107）；
  解锁条件与空军编队相同（军团=动员主义 civic，军队=合成技术 tech）；
  选中单位出“组建军团/军队”按钮 → 点相邻同型单位完成合并。
- **防空射程实数据化（新增）**：防空炮 Range=2、机动防空 Range=3 直接改进单位数据，
  面板“攻击范围”显示与截击结算、目标高亮三者一致（原版这两个单位 RangedCombat=0，
  Range 变更不影响普通攻击，只影响拦截半径与显示）。
- **机位租借（新增）**：在与其他玩家的交易界面（点对方头像 → 交易），
  “我的库存”列的**“协议”分组**里会出现租借行（与“开放边界”同一列表、同款样式）：
  - 点“机位租借：点击请求进驻”→ 向对方发出租借请求；
  - 对方打开与你的交易页时，其“协议”列表里会出现**“同意对方租用我方机位（点击）”**
    和**“拒绝机位租借请求（点击）”**两行——点“同意”即刻开放，无需完成任何交易；
  - 同意后：你的飞机用“部署”右键点对方的**航空港、市中心或跑道（含相邻格）**
    即可进驻，并把基地锚点迁过去（此后补给半径从对方机场算起）；
  - 双方状态互相独立、各自可收回：出租方交易页“已租机位给对方（点击收回）”；
  - 战争期间租借自动暂停（无法进驻新地块），恢复和平自动生效；
    每个回合开始会自动清账：锚点停在已无权使用的地块上的飞机会把锚点收回原位；
  - 状态存在玩家属性（PlayerProperties）里，进存档、多人/热座均可用；
  - 已知限制：AI 不会出租自己的机位（AI 无法点击按钮），只对人类玩家（含热座）有效；
    对方被租借的机场仍受原版机位上限约束（纯 Lua 改不了引擎的 AirSlots 计数）。

## 文件

- `Scripts/BetterAirUnits.lua`：核心逻辑（游戏内脚本，末尾含机位租借段）
- `UI/BetterAirUnitsDealView.lua`：交易页“协议”列表里的机位租借行（ReplaceUIScript DiplomacyDealView）
- `UI/BetterAirUnitsUI.lua` + `UI/BetterAirUnitsUI.xml`：操作完成后的通知兜底
- `Data/BetterAirUnits.xml`：给所有飞机加隐藏能力“移动后仍可攻击”
- `Text/BetterAirUnits_Text.xml`：能力文本
- `BetterAirUnits.modinfo`：模组清单

## 安装

1. 把整个 `BetterAirUnits` 文件夹复制到：
   `C:\Users\丁钰霖\Documents\My Games\Sid Meier's Civilization VI\Mods\`
2. 启动文明 6，在“额外内容 / Mods”里勾选 **Better Air Units - 移动力制飞机**。
3. 新开一局或读取存档（`AffectsSavedGames` 已开启，读取旧档也会生效）。

## 重要：必须开新游戏测试

Civ6 的存档会记录“创建这个存档时启用了哪些模组”。读取旧存档时，游戏只会加载
**存档当时的模组列表**，新启用的模组不会生效（这是游戏机制，不是模组问题）。
所以要测试本模组，请：

1. 在主菜单“额外内容 / Mods”里勾选本模组；
2. **新开一局**（或启用模组后再新建的存档）；
3. 造出飞机后测试“部署 1 格 -> 还能空袭”。

如果你只想在旧档里用，Civ6 本身不允许中途加入玩法类模组，只能开新档。

## 生效自检（每次改完必跑，游戏重启后再跑一次）

```
node DevTools/verify.mjs
```

它检查的是**引擎实际加载了什么**，不是“文件写没写”：

1. modinfo 结构：每个组件引用的文件都必须在 `<Files>` 清单里（集合差校验）。
   漏了不会报错，引擎只是**静默剔除该引用**——防空射程补丁 SQL 连续几轮没生效的第一个原因。
2. LoadOrder 竞争：本机其他模组的 `UpdateDatabase` 最大 LoadOrder = 2000000000，
   其中 **Bottlep Open Fire**（`NewAction`，LoadOrder=99999999）会执行
   `UPDATE Units SET RangedCombat = Combat - 15, Range = 1`，把防空炮/机动防空的射程抢回 1 格。
   所以本模组的射程补丁单独成组件 `BetterAirUnits_AAPatch`，`LoadOrder=2100000000`（最后加载才说话）。
3. 三向同步：桌面源码 == `Documents\...\Mods\BetterAirUnits` 逐文件哈希。
4. 上一局证据：Modding.log 里有没有 `Loading Data/BetterAirUnitsPatch.sql`、我们是否比 `NewAction` 晚应用、
   Lua.log 的加载标记，以及 `Cache\DebugGameplay.sqlite` 里读回的 Range 实际值（期望 2 / 3）。

### v5 修复项（2026-10-02）与验证要点

| 现象 | 真因 | 验证方法 |
|---|---|---|
| 对方已同意租借，点“改变基地”到对方城市**完全没反应、也没日志** | 原版 REBASE 的**鼠标左键**走 `OnMouseRebaseEnd`，里面 `IsSelectionAllowedAt(g_targetPlots)` 只认引擎算出的自家目标；我们上一版只重绑了 `PointerUp`（触屏），左键从没进过我们的函数 | 进入“改变基地”应看到日志 `rebase hl: N engine targets + M rented base tiles`；M>0 时左键点对方市中心 → `rebase relay` → `base updated (relay)` → `rent: base moved`，且**不再出现** `anchor guarded` |
| 飞机已经站在对方机场格上，基地却还在老家 | 引擎不允许 REBASE 到自己脚下格（无目标） | 回合开始自动认领：日志 `rent: anchor adopted` |
| 换基地后部署半径仍按旧基地算（X=0→X=15 后只能到 X=7） | 我们的 `TryFlyTo` 对 REBASE 也套了“离旧基地 ≤ 最大移动力”的二次限制 | 现在 REBASE 只受剩余移动力限制；日志里不再出现 `rebase: beyond base range` |
| 军队防空力量 97（=90+7），不是 +15 | 同一单位挂两条 `MODIFIER_UNIT_ADJUST_COMBAT_STRENGTH` **不叠加**，面板只认一条 | 军团显示 +7、军队显示 +15（防空炮 105 / 机动防空 115）；老档里合错的军队会在回合开始自动纠正 |
| 军队还能和军团合并 | gameplay 一直正确拒绝（`merge: invalid combination`），但按钮和高亮照样出 | 单机→只出“组建军团”；军团→只出“组建军队”；军队→两个都不出；高亮只亮合法目标 |
| 退出合并模式后地图留一团绿光 | 我们把高亮画在 `g_HexColoringMovement`，而原版 FORM_CORPS/ARMY 的 LEAVE 只清 `g_HexColoringPlacement` | 进/出“组建军团/军队”后绿块应立刻消失；换单位、ESC、点空白也清 |

日志关键字（`Lua.log`，UTF-16LE）：`rebase hl:` / `rebase relay` / `rent: base moved` /
`rent: anchor adopted` / `rent: GRANT` / `merge: ace wing` / `form corps refused`。

## 调试

模组里已经内置了 `[BetterAirUnits]` 调试日志。如果新档里仍然不生效，
把以下文件发给我即可：

- `C:\Users\丁钰霖\AppData\Local\Firaxis Games\Sid Meier's Civilization VI\Logs\Lua.log`
- 同目录下的 `Modding.log`、`Database.log`

我会从日志里看事件是否触发、移动力是否被补回。

## 测试清单（开新游戏！旧档不加载新模组）

1. 造防空炮/机动防空 → 与敌机相邻 → 出“攻击”按钮 → 点击后敌机受伤/坠毁、本回合结束；
2. 右击射程内敌机应直接开火（日志 `aa right-click`）；
3. 战列舰/导弹巡洋舰：对陆远程攻击照常，同时能打 3 格内飞机（两类高亮并存）；
4. 飞机回归：部署 1 格后仍能空袭；改变基地（REBASE）后日志应出现
   `rebase relay u=... -> (x,y)` 和 `base updated (relay)`（上轮修复一直没实测到，重点验证）；
5. 日志关键字：`[BetterAirUnits] aa fire`（结算）、`aa relay`（UI 中继）、`aa targets`（高亮）。
6. 机位租借（热座开新局）：A 打开与 B 的交易页 → 开“请求进驻对方机场”（日志 `rent relay op=req`）；
   B 打开与 A 的交易页应看到红色提示行（日志 `rent hooks installed` 存在 + `BetterAirRent` 前缀）；
   B 与 A 完成任意交易 → 日志 `rent: GRANT`；A 的飞机部署右键点 B 的航空港/市中心/跑道 →
   日志 `rent: base moved`；B 交易页点“收回” → 下一回合开始日志 `rent: anchor revoked`；
   B 点提示行拒绝 → 日志 `rent: rejected request`。

## 说明

- 对 AI 同样生效，避免只有玩家享受新机制（指移动力制部署/空袭；主动截击 AI 暂不会主动使用）。
- 机位占用（基地 2/3 架上限）引擎不支持，纯 Lua 无法修改。
