-- BetterAirUnits.lua
-- 让飞机按移动力行动：
--   改变基地（REBASE）后，按“原移动力 - 飞行距离”保留剩余移动力；
--   剩余移动力 > 0 时，飞机仍可继续空袭；
--   飞满全距离（剩余 0）时，和原版一样结束回合，不能空袭。
--
-- 原理：原版 REBASE 会把整回合移动力清零。这里在飞机移动完成后，
-- 用 UnitManager.ChangeMovesRemaining 把移动力补回剩余值，
-- 并用 UnitManager.RestoreUnitAttacks 恢复攻击次数。

local DEBUG = false;   -- 发布版：需要排障时改回 true

local function Log(msg)
    if DEBUG then
        print("[BetterAirUnits] " .. msg);
    end
end

-- 安全注册事件：单个事件不可用/报错时不让整个脚本中断
local function SafeAdd(event, handler, name)
    if event == nil then
        Log("event not available: " .. name);
        return;
    end
    -- 不同事件对象的 Add 签名不完全一样，两种调用方式都试一遍
    local ok, err = pcall(event.Add, handler);
    if not ok then
        ok, err = pcall(event.Add, event, handler);
    end
    if not ok then
        Log("event add failed: " .. name .. " -> " .. tostring(err));
    end
end

-- ===========================================================================
-- 属性访问加固（2026-10-03）—— 崩溃根因修复
-- ---------------------------------------------------------------------------
-- 逆向结论（转储 + 静态双向确认，见 __re_workshop/BAU_CRASH_GETPROPERTY.md）：
--   引擎的 GetProperty 是"全局唯一"的 Lua 绑定：整个 GameCore DLL 里只有一份
--   lGetProperty（RVA 0x1d500），它不看对象类型，直接调用 [obj.vtbl+0x50] 拿
--   "属性容器"再解引用。若传进来的是非属性对象（Lua table / 别的 context 的
--   stub / __instance 伪对象），或属性容器不可读，引擎会拿垃圾指针直接解引用：
--     EXCEPTION_ACCESS_VIOLATION  读地址 0x528
--     故障指令 mov rdx,[rsi]      GameCore RVA 0x1533e（函数 0x152f0..0x1539b）
--   2026-10-02 五次崩溃转储签名逐字节一致（13:11 / 15:40 / 16:27 / 18:33 / 19:34）。
--   pcall 挡不住原生崩溃 —— 必须先用纯 Lua 类型白名单把对象挡在门外。
-- ===========================================================================
local TRACE_PROPS = false;   -- 发布版：需要排障时改回 true
local g_PropTraceBudget = 20;   -- 每"轮"最多打印多少条诊断（避免全槽位扫描刷屏）
local function PropTrace(msg)
    if not TRACE_PROPS or g_PropTraceBudget <= 0 then return end
    g_PropTraceBudget = g_PropTraceBudget - 1;
    print(msg .. (g_PropTraceBudget == 0 and "   [后续 TRACE 已折叠]" or ""));
end   -- 诊断开关：打印被拦截的可疑属性访问；发布前可设 false

-- ⚠ HavokScript 没有 rawget！实测调用即 "function expected instead of nil"，
-- 而且这个错误发生在"主块"里会**中断整个文件后半段的加载**
-- （2026-10-03 热座局：BetterAirUnits.lua:937 主块报错 → 机位租借整段没注册）。
-- 读 __instance 只能用普通索引 + pcall 兜底（table 的 __index 可能是个会报错的函数）。
local function InstanceOf(o)
    local inst = nil;
    pcall(function() inst = o.__instance end);
    return inst;
end

-- 返回"可以安全交给引擎 GetProperty/SetProperty 的对象"：
--   userdata            → 原样返回
--   table 且有 __instance → 原样返回（引擎的 getobject(L,1,true) 自己会解包，
--                          原版 mod 全是这么调 pPlot:GetProperty 的）
--   其它（含裸 table）    → nil（以前就是这里取 [table+0x50] → 读 0x528 → 崩）
local function PropTarget(o)
    if o == nil then return nil end
    local t = type(o);
    if t == "userdata" then return o end
    if t == "table" then
        local inst = InstanceOf(o);
        if inst ~= nil and type(inst) == "userdata" then return o end
        return nil;
    end
    return nil;
end

-- 诊断用：把一个被拒绝的对象描述成人看得懂的一行
local function PropTargetDesc(o)
    if o == nil then return "nil" end
    local t = type(o);
    if t == "table" then
        local inst = InstanceOf(o);
        local has = "no __instance";
        if inst ~= nil then has = "__instance=" .. type(inst) end
        local id = "";
        pcall(function() if o.UnitID ~= nil then id = id .. " UnitID=" .. tostring(o.UnitID) end end);
        pcall(function() if o.PlayerID ~= nil then id = id .. " PlayerID=" .. tostring(o.PlayerID) end end);
        return "table[" .. has .. id .. "]";
    end
    return t;
end

local function GetProp(o, key)
    local t = PropTarget(o);
    if t == nil then
        PropTrace(string.format("[BetterAirUnits] GetProp BLOCKED obj=%s key=%s", PropTargetDesc(o), tostring(key)));
        return nil;
    end
    local ok, v = pcall(function() return t:GetProperty(key) end);
    if not ok then return nil; end
    return v;
end

local function SetProp(o, key, val)
    local t = PropTarget(o);
    if t == nil then
        PropTrace(string.format("[BetterAirUnits] SetProp BLOCKED obj=%s key=%s", PropTargetDesc(o), tostring(key)));
        return false;
    end
    local ok = pcall(function() t:SetProperty(key, val) end);
    return ok;
end

-- 玩家守卫：同样要走 PropTarget 解包 —— 热座/UI 上下文里 Players[i] 是 table，
-- 直接判 type(p)=="userdata" 会把两个人类玩家全判成"非存活"（实测热座局全灭）。
local function PlayerAlive(p)
    local t = PropTarget(p);
    if t == nil then return false end
    local ok, alive = pcall(function() return t:IsAlive() end);
    return ok and alive == true;
end

local g_AirState = {};  -- [playerId][unitId] = { x=, y=, moves=, applied=, pending= }
local AIR_BASE_X_KEY = "BetterAir_BaseX";
local AIR_BASE_Y_KEY = "BetterAir_BaseY";
local AIR_FORMATION_KEY = "BetterAir_Formation";

-- 前向声明：机位租借段（文件末尾）定义的函数，避免全局名解析为 nil
local MaybeMoveBaseToPartnerTile;
local RentGuardAnchor;
local RentSweepAll;
local RentAdoptAnchor;
local RentSyncHostMasks;
local CanRentLandAt;   -- handler 在前、定义在后，必须前向声明（否则按全局名解析成 nil）

local function IsAirUnit(unit)
    if unit == nil then
        return false;
    end
    local unitInfo = GameInfo.Units[unit:GetType()];
    return unitInfo ~= nil and unitInfo.Domain == "DOMAIN_AIR";
end

local function RecordUnit(playerId, unitId)
    local unit = UnitManager.GetUnit(playerId, unitId);
    if unit == nil or not IsAirUnit(unit) then
        return;
    end
    local x, y = unit:GetX(), unit:GetY();
    if x < 0 or y < 0 then
        return;  -- 单位还没放到地图上，等后续事件再记录
    end
    g_AirState[playerId] = g_AirState[playerId] or {};
    g_AirState[playerId][unitId] = {
        x = x,
        y = y,
        moves = unit:GetMovesRemaining(),
        applied = false,
        pending = nil,
    };
    if GetProp(unit, AIR_BASE_X_KEY) == nil or GetProp(unit, AIR_BASE_Y_KEY) == nil then
        SetProp(unit, AIR_BASE_X_KEY, x);
        SetProp(unit, AIR_BASE_Y_KEY, y);
    end
    Log(string.format("record p=%d u=%d at (%d,%d) moves=%d",
        playerId, unitId, x, y, unit:GetMovesRemaining()));
end

-- ===========================================================================
-- 空军编队探针：每个单位只测一次，把引擎是否允许空军合并写进日志。
-- ===========================================================================
local FORMATION_PROBE_KEY = "BetterAir_FormationProbe";

local function ProbeAirFormation(playerId, unit)
    if unit == nil or GetProp(unit, FORMATION_PROBE_KEY) ~= nil then
        return;
    end
    if MilitaryFormationTypes == nil then
        Log("probe formation: MilitaryFormationTypes not available");
        return;
    end
    SetProp(unit, FORMATION_PROBE_KEY, 1);

    local okCorps, canCorps = pcall(UnitManager.CanFormMilitaryFormation,
        playerId, unit:GetDomain(), MilitaryFormationTypes.CORPS_FORMATION, unit);
    local okArmy, canArmy = pcall(UnitManager.CanFormMilitaryFormation,
        playerId, unit:GetDomain(), MilitaryFormationTypes.ARMY_FORMATION, unit);

    local okCmd, canCmd = false, false;
    if UnitCommandTypes ~= nil then
        local tSelf = {};
        tSelf[UnitCommandTypes.PARAM_UNIT_PLAYER] = playerId;
        tSelf[UnitCommandTypes.PARAM_UNIT_ID] = unit:GetID();
        okCmd, canCmd = pcall(UnitManager.CanStartCommand, unit, UnitCommandTypes.FORM_CORPS, tSelf);
    end

    local unitInfo = GameInfo.Units[unit:GetType()];
    Log(string.format("probe formation p=%d u=%d domain=%s class=%s corps=%s army=%s cmdCorps=%s",
        playerId, unit:GetID(), tostring(unit:GetDomain()),
        tostring(unitInfo and unitInfo.FormationClass),
        tostring(okCorps and canCorps), tostring(okArmy and canArmy), tostring(okCmd and canCmd)));
end

local function RecordPlayerAirUnits(playerId)
    local player = Players[playerId];
    if player == nil or player:GetUnits() == nil then
        return;
    end
    local bHuman = player:IsHuman();
    for _, unit in player:GetUnits():Members() do
        RecordUnit(playerId, unit:GetID());
        if bHuman then
            ProbeAirFormation(playerId, unit);
        end
    end
end

local function RecordAllPlayers()
    for playerId, player in ipairs(Players) do
        RecordPlayerAirUnits(playerId);
    end
end

-- ===========================================================================
-- Air strike movement cost:
--   cost = maxMoves * distance * min(1, defenderStrength / attackerStrength)
-- Actual strengths come from the combat result table (base + modifiers).
-- Fractional costs accumulate in a unit property; whole points are deducted.
-- ===========================================================================
local COMBAT_MOVE_DEBT_KEY = "BetterAir_CombatMoveDebt";
local g_CombatSettlement = {};  -- [playerId][unitId] = { desired=, debt=, reapplied= }
local g_RestoringAfterCombat = false;
local g_AdjustingAfterCombat = false;

local function GetCombatantStrength(combatant)
    if combatant == nil then
        return 0;
    end
    local base = combatant[CombatResultParameters.COMBAT_STRENGTH] or 0;
    local bonus = combatant[CombatResultParameters.STRENGTH_MODIFIER] or 0;
    return base + bonus;
end

local function GetCombatantLocation(combatResult, combatant)
    local info = combatant[CombatResultParameters.ID];
    if info == nil then
        return nil;
    end

    local rx, ry = nil, nil;
    local source = "none";

    if info.type == ComponentType.UNIT then
        local unit = UnitManager.GetUnit(info.player, info.id);
        if unit ~= nil then
            local loc = unit:GetLocation();
            if loc ~= nil and loc.x ~= nil and loc.y ~= nil then
                rx, ry = loc.x, loc.y;
            else
                rx, ry = unit:GetX(), unit:GetY();
            end
            if rx ~= nil and ry ~= nil and rx >= 0 and ry >= 0 then
                source = "unit";
            else
                rx, ry = nil, nil;  -- 无效坐标，继续走 LOCATION 兜底
            end
        end
    elseif info.type == ComponentType.DISTRICT then
        local player = Players[info.player];
        if player ~= nil then
            -- ⚠ gameplay 上下文里 player:GetDistricts() 是 nil（会直接抛错让整个
            --   Events.Combat 处理器失效）。先 pcall 试引擎 API，失败再走"扫地块"兜底：
            --   district 一定在自己城市半径 3 内，用 plot:GetDistrictID() 命中。
            local district = nil;
            pcall(function()
                local ds = player:GetDistricts();
                if ds ~= nil then
                    district = ds:FindID(info.id);
                    if district == nil then
                        for _, d in ds:Members() do
                            if d:GetID() == info.id then district = d; break end
                        end
                    end
                end
            end);
            if district ~= nil then
                rx, ry = district:GetX(), district:GetY();
            else
                pcall(function()
                    for _, city in player:GetCities():Members() do
                        local cx, cy = city:GetX(), city:GetY();
                        if cx ~= nil and cy ~= nil then
                            local p0 = Map.GetPlot(cx, cy);
                            local did0 = -1;
                            if p0 ~= nil then pcall(function() did0 = p0:GetDistrictID() end) end;
                            if did0 == info.id then rx, ry = cx, cy; return end;
                            local nbs = Map.GetNeighborPlots(cx, cy, 3);
                            if nbs ~= nil then
                                for _, nb in ipairs(nbs) do
                                    local did = -1;
                                    pcall(function() did = nb:GetDistrictID() end);
                                    if did == info.id then rx, ry = nb:GetX(), nb:GetY(); return end;
                                end
                            end
                        end
                    end
                end);
            end
            if rx ~= nil and ry ~= nil and rx >= 0 and ry >= 0 then
                source = "district";
            else
                rx, ry = nil, nil;
            end
        end
    elseif ComponentType.CITY ~= nil and info.type == ComponentType.CITY then
        local player = Players[info.player];
        if player ~= nil then
            local city = player:GetCities():FindID(info.id);
            if city == nil then
                for _, c in player:GetCities():Members() do
                    if c:GetID() == info.id then
                        city = c;
                        break;
                    end
                end
            end
            if city ~= nil then
                rx, ry = city:GetX(), city:GetY();
                if rx ~= nil and ry ~= nil and rx >= 0 and ry >= 0 then
                    source = "city";
                else
                    rx, ry = nil, nil;
                end
            end
        end
    end

    if rx == nil then
        local location = combatResult[CombatResultParameters.LOCATION];
        if location ~= nil then
            rx, ry = location.x, location.y;
            source = "location";
        end
    end

    Log(string.format("combat loc type=%s p=%s id=%s src=%s at (%s,%s)",
        tostring(info.type), tostring(info.player), tostring(info.id), source,
        tostring(rx), tostring(ry)));
    return rx, ry;
end

local ApplyCombatSettlement;

local function GetFallbackStrength(unit)
    if unit == nil then
        return 0;
    end
    local info = GameInfo.Units[unit:GetType()];
    if info == nil then
        return 0;
    end
    return info.RangedCombat or info.Bombard or info.Combat or 0;
end

local function OnAirCombat(combatResult)
    if combatResult == nil then
        return;
    end
    local attacker = combatResult[CombatResultParameters.ATTACKER];
    local defender = combatResult[CombatResultParameters.DEFENDER];
    if attacker == nil or defender == nil then
        return;
    end

    local attInfo = attacker[CombatResultParameters.ID];
    if attInfo == nil or attInfo.type ~= ComponentType.UNIT then
        return;
    end

    local unit = UnitManager.GetUnit(attInfo.player, attInfo.id);
    if unit == nil or not IsAirUnit(unit) then
        return;
    end

    local ax, ay = unit:GetX(), unit:GetY();
    if ax < 0 or ay < 0 then
        return;
    end
    local dx, dy = GetCombatantLocation(combatResult, defender);
    if dx == nil or dy == nil then
        Log("combat: cannot resolve defender location, skip");
        return;
    end

    local distance = Map.GetPlotDistance(ax, ay, dx, dy);
    if distance < 1 then
        distance = 1;
    end
    if distance > 500 then
        Log(string.format("combat: distance suspiciously large (%d), still using it", distance));
    end

    local attStrength = GetCombatantStrength(attacker);
    local defStrength = GetCombatantStrength(defender);
    if attStrength <= 0 or defStrength <= 0 then
        local defUnit = nil;
        local defInfo = defender[CombatResultParameters.ID];
        if defInfo ~= nil and defInfo.type == ComponentType.UNIT then
            defUnit = UnitManager.GetUnit(defInfo.player, defInfo.id);
        end
        attStrength = attStrength > 0 and attStrength or GetFallbackStrength(unit);
        defStrength = defStrength > 0 and defStrength or GetFallbackStrength(defUnit);
        if attStrength <= 0 or defStrength <= 0 then
            Log("combat: missing strength, skip");
            return;
        end
    end

    local ratio = math.min(1, defStrength / attStrength);
    local cost = unit:GetMaxMoves() * distance * ratio;

    -- 引擎会在战斗结算前先把移动力清零，所以“攻击前移动力”用我们自己记录的状态
    local movesBefore = unit:GetMaxMoves();
    local playerState = g_AirState[attInfo.player];
    local st = playerState and playerState[unit:GetID()];
    if st ~= nil and st.moves ~= nil then
        movesBefore = st.moves;
    end

    local debt = GetProp(unit, COMBAT_MOVE_DEBT_KEY) or 0;
    debt = debt + cost;
    local deduct = math.min(math.floor(debt), movesBefore);
    local desired = movesBefore - deduct;
    local newDebt = debt - deduct;

    SetProp(unit, COMBAT_MOVE_DEBT_KEY, newDebt);
    if st ~= nil then
        st.moves = desired;
    end

    g_CombatSettlement[attInfo.player] = g_CombatSettlement[attInfo.player] or {};
    g_CombatSettlement[attInfo.player][unit:GetID()] = {
        desired = desired,
        debt = newDebt,
        reapplied = 0,
    };

    Log(string.format("combat p=%d u=%d dist=%d atk=%.1f def=%.1f ratio=%.3f cost=%.3f before=%d desired=%d moves=%d",
        attInfo.player, unit:GetID(), distance, attStrength, defStrength, ratio, cost,
        movesBefore, desired, unit:GetMovesRemaining()));

    ApplyCombatSettlement(attInfo.player, unit:GetID());
end

ApplyCombatSettlement = function(playerId, unitId)
    local pending = g_CombatSettlement[playerId] and g_CombatSettlement[playerId][unitId];
    if pending == nil then
        return;
    end

    local unit = UnitManager.GetUnit(playerId, unitId);
    if unit == nil then
        g_CombatSettlement[playerId][unitId] = nil;
        return;
    end

    -- 引擎会把“本回合已行动”的状态和移动力一起清掉，只补移动力不够：
    -- 必须先 RestoreMovement（和作弊菜单“回复行动”一致），再把移动力调回期望值。
    g_RestoringAfterCombat = true;
    UnitManager.RestoreMovement(unit);
    UnitManager.RestoreUnitAttacks(unit);
    g_RestoringAfterCombat = false;

    g_AdjustingAfterCombat = true;
    local delta = pending.desired - unit:GetMaxMoves();
    if delta ~= 0 then
        UnitManager.ChangeMovesRemaining(unit, delta);
    end
    g_AdjustingAfterCombat = false;
    local playerState = g_AirState[playerId];
    local st = playerState and playerState[unitId];
    if st ~= nil then
        st.moves = pending.desired;
    end
    SetProp(unit, COMBAT_MOVE_DEBT_KEY, pending.debt);

    pending.reapplied = pending.reapplied + 1;
    Log(string.format("settle p=%d u=%d desired=%d reapplied=%d moves=%d",
        playerId, unitId, pending.desired, pending.reapplied, unit:GetMovesRemaining()));

    if pending.reapplied >= 5 then
        g_CombatSettlement[playerId][unitId] = nil;
    end
end

-- ===========================================================================
-- 是否交战：用 GetDiplomaticStateID 对比 DIPLOSTATE_WAR（比 IsAtWarWith 可靠，读取失败按"未交战"）
-- 放在这里是因为后面的 free-flight handler 要用（Lua local 作用域从定义点开始）
local function AtWar(aId, bId)
    if aId == nil or bId == nil or aId == bId or bId < 0 then return false end
    local pa = Players[aId];
    if pa == nil then return false end
    local warIdx = nil;
    pcall(function()
        local row = GameInfo.DiplomaticStates["DIPLOSTATE_WAR"];
        if row ~= nil then warIdx = row.Index end
    end);
    local state = nil;
    pcall(function() state = pa:GetDiplomacy():GetDiplomaticStateID(bId) end);
    if state ~= nil and warIdx ~= nil then return state == warIdx end;
    local ok, war = pcall(function() return pa:GetDiplomacy():IsAtWarWith(bId) end);
    if ok and war ~= nil then return war == true end;
    return false;
end

-- 锚点自愈（2026-10-03）
-- 不变量：飞机的基地锚点离自己**不可能**超过 maxMoves。
--   一旦超过，说明锚点过期了 —— 典型现象就是用户报的
--   "改基地到 X=15 之后，部署只能到 X=7"（部署范围被旧基地 X=0 的半径切掉）。
--   UI 侧读 unit 属性可能拿到过期镜像，所以 gameplay 侧必须有这个兜底。
-- ===========================================================================
local function HealBaseAnchor(unit, why)
    if unit == nil or not IsAirUnit(unit) then return false end
    local ux, uy = unit:GetX(), unit:GetY();
    if ux == nil or uy == nil or ux < 0 or uy < 0 then return false end
    local maxMoves = unit:GetMaxMoves() or 0;
    local bx, by = GetProp(unit, AIR_BASE_X_KEY), GetProp(unit, AIR_BASE_Y_KEY);
    if bx == nil or by == nil then
        SetProp(unit, AIR_BASE_X_KEY, ux);
        SetProp(unit, AIR_BASE_Y_KEY, uy);
        Log(string.format("anchor heal (%s) u=%d -> (%d,%d) [was nil]", tostring(why), unit:GetID(), ux, uy));
        return true;
    end
    local d = Map.GetPlotDistance(bx, by, ux, uy);
    if d > maxMoves then
        SetProp(unit, AIR_BASE_X_KEY, ux);
        SetProp(unit, AIR_BASE_Y_KEY, uy);
        Log(string.format("anchor heal (%s) u=%d (%d,%d)->(%d,%d) oldDist=%d max=%d",
            tostring(why), unit:GetID(), bx, by, ux, uy, d, maxMoves));
        return true;
    end
    return false;
end

local function ApplyAdjustment(playerId, unitId, st, newX, newY, remaining)
    local unit = UnitManager.GetUnit(playerId, unitId);
    if unit == nil then
        return;
    end

    -- 只剩 0 移动力：不补攻击，保持原版“飞满全距离 = 回合结束”
    if remaining > 0 then
        UnitManager.RestoreUnitAttacks(unit);
        local delta = remaining - unit:GetMovesRemaining();
        if delta ~= 0 then
            UnitManager.ChangeMovesRemaining(unit, delta);
        end
        Log(string.format("adjust p=%d u=%d -> (%d,%d) dist=%d remaining=%d (moves now %d)",
            playerId, unitId, newX, newY, Map.GetPlotDistance(st.x, st.y, newX, newY), remaining, unit:GetMovesRemaining()));
    else
        -- 确保攻击次数也被消耗，避免“飞满距离还能空袭”
        UnitManager.FinishMoves(unit);
        Log(string.format("full move p=%d u=%d -> (%d,%d) dist=%d, turn ends",
            playerId, unitId, newX, newY, Map.GetPlotDistance(st.x, st.y, newX, newY)));
    end

    st.x = newX;
    st.y = newY;
    st.moves = remaining;
    st.applied = true;
    st.pending = nil;
    -- 飞完之后锚点必须仍然"够得着"自己，否则就是过期锚点
    HealBaseAnchor(unit, "after-flight");
end

local function AdjustAirUnitMoves(playerId, unitId)
    local unit = UnitManager.GetUnit(playerId, unitId);
    if unit == nil or not IsAirUnit(unit) then
        return;
    end

    local playerState = g_AirState[playerId];
    if playerState == nil then
        RecordUnit(playerId, unitId);
        return;
    end
    local st = playerState[unitId];
    if st == nil then
        RecordUnit(playerId, unitId);
        return;
    end

    local newX, newY = unit:GetX(), unit:GetY();

    -- 位置没变，不是一次飞行
    if st.x == newX and st.y == newY then
        return;
    end

    local distance = Map.GetPlotDistance(st.x, st.y, newX, newY);
    local movesBefore = st.moves or unit:GetMaxMoves();
    if movesBefore <= 0 then
        -- 状态过期（例如上一回合结束后没有刷新）：按本回合满移动力算
        movesBefore = unit:GetMaxMoves();
        Log(string.format("state refresh fallback p=%d u=%d maxMoves=%d",
            playerId, unitId, movesBefore));
    end
    local remaining = math.max(0, movesBefore - distance);

    -- 引擎还没扣完移动力（事件来得太早）：挂起，等移动力变化后再补
    if unit:GetMovesRemaining() > remaining then
        st.pending = {
            x = newX,
            y = newY,
            remaining = remaining,
        };
        Log(string.format("early event p=%d u=%d dist=%d remaining=%d, pending",
            playerId, unitId, distance, remaining));
        return;
    end

    ApplyAdjustment(playerId, unitId, st, newX, newY, remaining);
end

-- 单位传送 / 移动完成时调整（对本地和 AI 都生效）
SafeAdd(Events.UnitTeleported, AdjustAirUnitMoves, "UnitTeleported");
SafeAdd(Events.UnitMoveComplete, AdjustAirUnitMoves, "UnitMoveComplete");
SafeAdd(Events.UnitMovementPointsRestored, function(playerId, unitId)
    local unit = UnitManager.GetUnit(playerId, unitId);
    if unit ~= nil and IsAirUnit(unit) and not g_RestoringAfterCombat then
        SetProp(unit, COMBAT_MOVE_DEBT_KEY, 0);
    end
    if not g_RestoringAfterCombat and g_CombatSettlement[playerId] ~= nil then
        g_CombatSettlement[playerId][unitId] = nil;
    end
    RecordUnit(playerId, unitId);
end, "UnitMovementPointsRestored");

-- 空袭/拦截等战斗结束后，按实际战力比值扣移动力
SafeAdd(Events.Combat, OnAirCombat, "Combat");

-- 操作段完成时也尝试调整（能覆盖 AI 的 REBASE；事件不存在就跳过）
local function OnAirOperationSegment(playerId, unitId, hCommand)
    AdjustAirUnitMoves(playerId, unitId);
    if hCommand == UnitOperationTypes.REBASE then
        local unit = UnitManager.GetUnit(playerId, unitId);
        if unit ~= nil and IsAirUnit(unit) and unit:GetX() >= 0 and unit:GetY() >= 0 then
            local gx, gy = unit:GetX(), unit:GetY();
            local obx, oby = GetProp(unit, AIR_BASE_X_KEY), GetProp(unit, AIR_BASE_Y_KEY);
            SetProp(unit, AIR_BASE_X_KEY, gx);
            SetProp(unit, AIR_BASE_Y_KEY, gy);
            Log(string.format("base updated p=%d u=%d -> (%d,%d)", playerId, unitId, gx, gy));
            MaybeMoveBaseToPartnerTile(playerId, unit, gx, gy);
            RentGuardAnchor(playerId, unit, obx, oby);
        end
    end
end
SafeAdd(Events.UnitOperationSegmentComplete, OnAirOperationSegment, "UnitOperationSegmentComplete");
SafeAdd(Events.UnitOperationsCleared, OnAirOperationSegment, "UnitOperationsCleared");

-- 移动力变化时，处理之前因“事件太早”而挂起的调整
SafeAdd(Events.UnitMovementPointsChanged, function(playerId, unitId)
        local playerState = g_AirState[playerId];
        local st = playerState and playerState[unitId];
        if st ~= nil and st.pending ~= nil then
            AdjustAirUnitMoves(playerId, unitId);
        end
        local unit = UnitManager.GetUnit(playerId, unitId);
        local pending = g_CombatSettlement[playerId] and g_CombatSettlement[playerId][unitId];
        if not g_AdjustingAfterCombat and unit ~= nil and pending ~= nil and unit:GetMovesRemaining() == 0 then
            ApplyCombatSettlement(playerId, unitId);
        end
    end, "UnitMovementPointsChanged");

-- 空袭操作完全结束时再补一次移动力（若引擎在战斗后再次清零，上面的事件会再补）
SafeAdd(Events.UnitOperationSegmentComplete, function(playerId, unitId, hCommand)
    if hCommand == UnitOperationTypes.AIR_ATTACK then
        ApplyCombatSettlement(playerId, unitId);
    end
end, "CombatSettlementSegment");
SafeAdd(Events.UnitOperationsCleared, function(playerId, unitId, hCommand)
    if hCommand == UnitOperationTypes.AIR_ATTACK then
        ApplyCombatSettlement(playerId, unitId);
    end
end, "CombatSettlementCleared");

-- 自由飞行：UI 在引擎拒绝 REBASE（迷雾/敌方领土）时调用
SafeAdd(GameEvents.BetterAirFreeFlight, function(playerId, params)
    if params == nil or params.UnitID == nil or params.X == nil or params.Y == nil then
        return;
    end
    local unit = UnitManager.GetUnit(playerId, params.UnitID);
    if unit == nil or not IsAirUnit(unit) then
        return;
    end

    local x, y = params.X, params.Y;
    -- 进入时的快照。用户实测"反复点不动的目标会把移动力耗光"，
    -- 这里保证：只要飞机最终没动，就把可能被引擎/事件链扣掉的移动力还回去。
    local entryX, entryY = unit:GetX(), unit:GetY();
    local entryMoves = unit:GetMovesRemaining();
    local function RefundIfNotMoved(why)
        local cx, cy = unit:GetX(), unit:GetY();
        if cx == entryX and cy == entryY then
            local cur = unit:GetMovesRemaining();
            if entryMoves ~= nil and cur ~= nil and cur < entryMoves then
                local okR = pcall(UnitManager.ChangeMovesRemaining, unit, entryMoves - cur);
                if okR then
                    Log(string.format("free flight: REFUND %d moves (%s) %d->%d",
                        entryMoves - cur, tostring(why), cur, entryMoves));
                end
            end
        end
    end
    local dist = Map.GetPlotDistance(entryX, entryY, x, y);
    Log(string.format("free flight: ENTER u=%d pos=(%d,%d) moves=%s -> (%d,%d) dist=%d rebase=%s",
        unit:GetID(), entryX, entryY, tostring(entryMoves), x, y, dist, tostring(params.Rebase)));
    if dist < 1 then
        RefundIfNotMoved("dist<1");
        return;
    end
    if dist > unit:GetMovesRemaining() then
        Log(string.format("free flight: out of range dist=%d moves=%d, skip", dist, unit:GetMovesRemaining()));
        RefundIfNotMoved("out-of-range");
        return;
    end

    local baseX = GetProp(unit, AIR_BASE_X_KEY);
    local baseY = GetProp(unit, AIR_BASE_Y_KEY);
    if baseX == nil or baseY == nil then
        baseX, baseY = unit:GetX(), unit:GetY();
    end
    local baseDist = Map.GetPlotDistance(baseX, baseY, x, y);
    -- REBASE（改变基地）只受剩余移动力限制：否则“把基地搬到 19 格外的伙伴机场”永远被
    -- “离旧基地太远”挡死（用户报的 X=0→X=15 之后只能到 X=7 就是这个）。
    if params.Rebase ~= 1 and baseDist > unit:GetMaxMoves() then
        Log(string.format("free flight: beyond base range baseDist=%d max=%d, skip", baseDist, unit:GetMaxMoves()));
        RefundIfNotMoved("beyond-base-range");
        return;
    end

    local plot = Map.GetPlot(x, y);
    if plot == nil then
        Log("free flight: invalid plot, skip");
        return;
    end

    -- 改基地到"别人的地"必须持有有效租借授权；撤销后立即失效。
    -- 原来这里完全没有授权校验（params.Rebase==1 还会跳过基地半径检查），
    -- 于是"收回同意后飞机照样能搬过去"（2026-10-03 实测日志：no grant 之后仍然 free flight 成功）。
    local targetOwner = -1;
    pcall(function() targetOwner = plot:GetOwner() end);
    if params.Rebase == 1 and targetOwner ~= nil and targetOwner >= 0 and targetOwner ~= playerId then
        if CanRentLandAt == nil or not CanRentLandAt(playerId, x, y) then
            Log(string.format("free flight: rebase to foreign tile (%d,%d) owner=%d WITHOUT grant, rejected",
                x, y, targetOwner));
            RefundIfNotMoved("no-grant");
            return;
        end
    end
    local unitsAtPlot = Map.GetUnitsAt(plot);
    if unitsAtPlot ~= nil then
        for other in unitsAtPlot:Units() do
            local otherOwner = other:GetOwner();
            -- ⚠ 只有"敌国"才拦。原来只判 other:GetOwner() ~= playerId，
            --   于是**友方/租借伙伴的市中心驻军会把落点挡死**（实测 14 次
            --   "target occupied by enemy, skip" 全发生在对方市中心）。
            if otherOwner ~= playerId and AtWar(playerId, otherOwner) then
                Log(string.format("free flight: target occupied by HOSTILE unit (owner=%d), skip", otherOwner));
                return;
            end
        end
    end

    RecordUnit(playerId, unit:GetID());
    local ok = pcall(UnitManager.PlaceUnit, unit, x, y);
    if not ok then
        Log("free flight: PlaceUnit failed");
        RefundIfNotMoved("PlaceUnit-error");
        return;
    end
    if unit:GetX() ~= x or unit:GetY() ~= y then
        -- 富诊断：为什么放不下去（机位满？是城市？区域类型？）
        local tOwner2, isCity2, dType2, airN2 = -1, false, -1, -1;
        pcall(function() tOwner2 = plot:GetOwner() end);
        pcall(function() isCity2 = plot:IsCity() end);
        pcall(function() dType2 = plot:GetDistrictType() end);
        pcall(function()
            local au = plot:GetAirUnits();
            if au ~= nil then
                airN2 = 0;
                for _ in au:Units() do airN2 = airN2 + 1 end
            end
        end);
        Log(string.format("free flight: did not move (now %d,%d) target owner=%d isCity=%s district=%s airUnitsOnPlot=%s moves=%s",
            unit:GetX(), unit:GetY(), tostring(tOwner2), tostring(isCity2), tostring(dType2),
            tostring(airN2), tostring(unit:GetMovesRemaining())));
        RefundIfNotMoved("did-not-move");
        return;
    end

    -- PlaceUnit 不会自己扣移动力，手动按距离扣
    local st = g_AirState[playerId] and g_AirState[playerId][unit:GetID()];
    local movesBefore = unit:GetMaxMoves();
    if st ~= nil and st.moves ~= nil then
        movesBefore = st.moves;
    end
    local remaining = math.max(0, movesBefore - dist);
    local delta = remaining - unit:GetMovesRemaining();
    if delta ~= 0 then
        UnitManager.ChangeMovesRemaining(unit, delta);
    end
    AdjustAirUnitMoves(playerId, unit:GetID());
    MaybeMoveBaseToPartnerTile(playerId, unit, x, y);
    -- 以 REBASE 意图自由飞行：锚点一律迁到新基地
    -- （他人地块在前面已通过授权校验；MaybeMoveBaseToPartnerTile 也会写，这里兜底）
    if params.Rebase == 1 then
        local o = -1
        pcall(function() o = plot:GetOwner() end)
        SetProp(unit, AIR_BASE_X_KEY, x)
        SetProp(unit, AIR_BASE_Y_KEY, y)
        Log(string.format("rebase (free flight): base -> (%d,%d) owner=%d", x, y, o))
    end
    HealBaseAnchor(unit, "after-free-flight");
    Log(string.format("free flight p=%d u=%d -> (%d,%d) dist=%d remaining=%d moves=%d base=(%s,%s)",
        playerId, unit:GetID(), x, y, dist, remaining, unit:GetMovesRemaining(),
        tostring(GetProp(unit, AIR_BASE_X_KEY)), tostring(GetProp(unit, AIR_BASE_Y_KEY))));
end, "BetterAirFreeFlight");

-- ===========================================================================
-- 自研空军编队：2 架同型单机 -> 机群(+7)；机群 + 1 架同型单机 -> 王牌机队(+8)
-- ===========================================================================
local function CopyPromotions(leader, absorb)
    local leaderExp = leader:GetExperience();
    local absorbExp = absorb:GetExperience();
    if leaderExp == nil or absorbExp == nil then
        Log("merge: experience unavailable, cannot copy promotions");
        return;
    end
    local copied = 0;
    for row in GameInfo.UnitPromotions() do
        local index = row.Index;
        if absorbExp:HasPromotion(index) and not leaderExp:HasPromotion(index) then
            local ok, err = pcall(leaderExp.SetPromotion, leaderExp, index, true);
            if ok then
                copied = copied + 1;
                Log(string.format("merge: copied promotion %s (%d)", tostring(row.UnitPromotionType), index));
            else
                Log(string.format("merge: copy promotion %s failed: %s", tostring(row.UnitPromotionType), tostring(err)));
            end
        end
    end
    Log(string.format("merge: copied %d promotions", copied));
end

local function PlayerHasCivic(player, civicType)
    if player == nil or player:GetCulture() == nil or GameInfo == nil or GameInfo.Civics == nil then
        return false;
    end
    local row = GameInfo.Civics[civicType];
    return row ~= nil and player:GetCulture():HasCivic(row.Index);
end

local function PlayerHasTech(player, techType)
    if player == nil or player:GetTechs() == nil or GameInfo == nil or GameInfo.Technologies == nil then
        return false;
    end
    local row = GameInfo.Technologies[techType];
    return row ~= nil and player:GetTechs():HasTech(row.Index);
end

-- 防空单位合并资格（与截击同规则；这里独立实现，避免依赖文件后段的 local）
local function IsAAMergeEligible(unit)
    if unit == nil then
        return false;
    end
    local info = GameInfo.Units[unit:GetType()];
    if info == nil or info.Domain == "DOMAIN_AIR" then
        return false;
    end
    local at = info.CanTargetAir;
    return (at == true or tonumber(at) == 1) or (tonumber(info.AntiAirCombat) or 0) > 0;
end

-- 强度能力同步：军团 = ABILITY_BETTER_AIR_SQUADRON(+7)，军队 = ABILITY_BETTER_AIR_ACE(+15 总额)。
-- 关键：单位身上永远只保留一个 MODIFIER_UNIT_ADJUST_COMBAT_STRENGTH ——
-- 实测两条同类修正不叠加（军队只显示 +7），所以升级军队时必须先摘掉机群的 +7。
local g_AbilityProbeLogged = false;
local g_AbilityBlind = false;   -- 由 SyncFormationAbilities 设置：本次是否允许盲操作
local function SetAbilityCount(unit, abilityType, want)
    if unit == nil then return; end
    local ok, err = pcall(function()
        local stack = unit:GetAbility();
        if stack == nil then Log("merge: unit:GetAbility() nil"); return; end
        local have = 0;
        local mode = "blind";
        local okc, c = pcall(function() return stack:GetAbilityCount(abilityType) end);
        if okc and c ~= nil then
            have = tonumber(c) or 0; mode = "GetAbilityCount";
        else
            local okh, h = pcall(function() return stack:HasAbility(abilityType) end);
            if okh then have = h and 1 or 0; mode = "HasAbility"; end
        end
        if not g_AbilityProbeLogged then
            Log(string.format("ability probe: api=%s %s have=%d want=%d", mode, tostring(abilityType), have, want));
            g_AbilityProbeLogged = true;
        end
        if mode == "blind" then
            if not g_AbilityBlind then
                Log(string.format("merge: 计数 API 不可用且非合并时机，跳过 %s（避免每回合重复加减）", tostring(abilityType)));
                return;
            end
            -- 计数 API 都不可用：升级路径上每个能力最多 1 层，直接盲操作（引擎会夹到 0）
            if want == 0 then stack:ChangeAbilityCount(abilityType, -1);
            else stack:ChangeAbilityCount(abilityType, 1); end
            return;
        end
        if have < want then
            stack:ChangeAbilityCount(abilityType, want - have);
        elseif have > want then
            stack:ChangeAbilityCount(abilityType, -(have - want));
        end
        local _, now = pcall(function() return stack:GetAbilityCount(abilityType) end);
        Log(string.format("merge: ability %s -> want=%d now=%s", tostring(abilityType), want, tostring(now)));
    end);
    if not ok then
        Log(string.format("merge: set ability %s failed: %s", tostring(abilityType), tostring(err)));
    end
end

-- allowBlind：只有在“刚刚发生合并”的那一次才允许在计数 API 不可用时盲操作；
-- 回合开始的修复扫描如果读不到计数就什么都不做，否则会每回合重复 +1。
local function SyncFormationAbilities(unit, allowBlind)
    if unit == nil then return; end
    local f = GetProp(unit, AIR_FORMATION_KEY) or 0;
    g_AbilityBlind = (allowBlind == true);
    SetAbilityCount(unit, "ABILITY_BETTER_AIR_SQUADRON", f == 1 and 1 or 0);
    SetAbilityCount(unit, "ABILITY_BETTER_AIR_ACE",       f >= 2 and 1 or 0);
    -- 防空单位：ACE/SQUADRON 只挂 CLASS_AIRCRAFT，挂不到防空单位上（所以以前这里是空操作）。
    -- 防空走专用能力 ABILITY_BETTER_AIR_AA_ACE（Tag=CLASS_ANTI_AIR，Amount=+8）：
    --   引擎己经给了"军团/军队各 +7"，补 +8 后军队面板 = 基础 + 15，与承诺一致。
    SetAbilityCount(unit, "ABILITY_BETTER_AIR_AA_ACE",    f >= 2 and 1 or 0);
end

-- 回合开始修复：把历史存档里“军团+军队能力同时挂着（面板只显示 +7）”的单位纠正过来
local function FormationRepairAll()
    for playerId = 0, GameDefines.MAX_PLAYERS - 1 do
        local p = Players[playerId];
        if p ~= nil and p:IsAlive() and not p:IsBarbarian() and p:GetUnits() ~= nil then
            local ok = pcall(function()
                for _, unit in p:GetUnits():Members() do
                    if unit ~= nil and GetProp(unit, AIR_FORMATION_KEY) ~= nil then
                        SyncFormationAbilities(unit);
                    end
                end
            end);
            if not ok then Log("merge: formation repair pass failed"); end
        end
    end
end

SafeAdd(GameEvents.BetterAirMerge, function(playerId, params)
    if params == nil or params.LeaderID == nil or params.AbsorbID == nil then
        return;
    end
    local leader = UnitManager.GetUnit(playerId, params.LeaderID);
    local absorb = UnitManager.GetUnit(playerId, params.AbsorbID);
    if leader == nil or absorb == nil then
        Log("merge: invalid units, skip");
        return;
    end
    local bothAir = IsAirUnit(leader) and IsAirUnit(absorb);
    local bothAA = IsAAMergeEligible(leader) and IsAAMergeEligible(absorb);
    if not bothAir and not bothAA then
        Log("merge: not both-air nor both-AA, skip");
        return;
    end
    if leader:GetType() ~= absorb:GetType() then
        Log("merge: type mismatch, skip");
        return;
    end
    if Map.GetPlotDistance(leader:GetX(), leader:GetY(), absorb:GetX(), absorb:GetY()) > 1 then
        Log("merge: not same/adjacent tile, skip");
        return;
    end

    local formation = GetProp(leader, AIR_FORMATION_KEY) or 0;
    local absorbFormation = GetProp(absorb, AIR_FORMATION_KEY) or 0;

    -- 允许“选单机、点机群”的顺序：把机群换到主机位置
    if formation == 0 and absorbFormation == 1 then
        leader, absorb = absorb, leader;
        formation = 1;
        absorbFormation = 0;
    end

    local player = Players[playerId];
    if formation == 0 and absorbFormation == 0 then
        if not PlayerHasCivic(player, "CIVIC_MOBILIZATION") then
            Log("merge: squadron requires CIVIC_MOBILIZATION, skip");
            return;
        end
        Log("merge: squadron unlock ok (CIVIC_MOBILIZATION)");
        CopyPromotions(leader, absorb);
        SetProp(leader, AIR_FORMATION_KEY, 1);
        SyncFormationAbilities(leader, true);
        if MilitaryFormationTypes ~= nil then
            leader:SetMilitaryFormation(MilitaryFormationTypes.CORPS_FORMATION);
        end
        if g_AirState[playerId] ~= nil then
            g_AirState[playerId][absorb:GetID()] = nil;
        end
        UnitManager.Kill(absorb);
        Log(string.format("merge: squadron p=%d leader=%d absorb=%d", playerId, leader:GetID(), absorb:GetID()));
    elseif formation == 1 and absorbFormation == 0 then
        if not PlayerHasTech(player, "TECH_COMBINED_ARMS") then
            Log("merge: ace wing requires TECH_COMBINED_ARMS, skip");
            return;
        end
        Log("merge: ace wing unlock ok (TECH_COMBINED_ARMS)");
        CopyPromotions(leader, absorb);
        SetProp(leader, AIR_FORMATION_KEY, 2);
        SyncFormationAbilities(leader, true);
        if MilitaryFormationTypes ~= nil then
            leader:SetMilitaryFormation(MilitaryFormationTypes.ARMY_FORMATION);
        end
        if g_AirState[playerId] ~= nil then
            g_AirState[playerId][absorb:GetID()] = nil;
        end
        UnitManager.Kill(absorb);
        Log(string.format("merge: ace wing p=%d leader=%d absorb=%d", playerId, leader:GetID(), absorb:GetID()));
    else
        Log(string.format("merge: invalid combination leader=%d absorb=%d", formation, absorbFormation));
    end
end, "BetterAirMerge");

-- UI 在 REBASE 操作完全结束后，通过 EXECUTE_SCRIPT 通知这里（兜底）
SafeAdd(GameEvents.ScenarioCommand_BetterAirRebaseComplete, function(playerId, params)
    local unitId = params and params.UnitID;
    if unitId == nil then
        return;
    end
    AdjustAirUnitMoves(playerId, unitId);
    local unit = UnitManager.GetUnit(playerId, unitId);
    if unit ~= nil and IsAirUnit(unit) then
        local oldBX, oldBY = GetProp(unit, AIR_BASE_X_KEY), GetProp(unit, AIR_BASE_Y_KEY);
        local bx, by = params.X, params.Y;
        if bx == nil or by == nil then
            bx, by = unit:GetX(), unit:GetY();
        end
        if bx ~= nil and by ~= nil and bx >= 0 and by >= 0 then
            SetProp(unit, AIR_BASE_X_KEY, bx);
            SetProp(unit, AIR_BASE_Y_KEY, by);
            Log(string.format("base updated (relay) p=%d u=%d -> (%d,%d)", playerId, unitId, bx, by));
            if bx ~= oldBX or by ~= oldBY then
                MaybeMoveBaseToPartnerTile(playerId, unit, bx, by);
                RentGuardAnchor(playerId, unit, oldBX, oldBY);
            end
        end
    end
end, "ScenarioCommand_BetterAirRebaseComplete");

-- UI 在 DEPLOY 操作完全结束后通知这里（只调整移动力，不改基地）
SafeAdd(GameEvents.ScenarioCommand_BetterAirDeployComplete, function(playerId, params)
    local unitId = params and params.UnitID;
    if unitId ~= nil then
        AdjustAirUnitMoves(playerId, unitId);
        local unit = UnitManager.GetUnit(playerId, unitId);
        if unit ~= nil and IsAirUnit(unit) then
            MaybeMoveBaseToPartnerTile(playerId, unit, unit:GetX(), unit:GetY());
        end
    end
end, "ScenarioCommand_BetterAirDeployComplete");

-- 回合开始 / 单位创建时记录状态
SafeAdd(GameEvents.PlayerTurnStarted, RecordPlayerAirUnits, "PlayerTurnStarted");
SafeAdd(GameEvents.OnGameTurnStarted, RecordAllPlayers, "OnGameTurnStarted");
SafeAdd(GameEvents.OnGameTurnStarted, function() pcall(RentSweepAll); pcall(FormationRepairAll) end, "RentSweepAll");
SafeAdd(GameEvents.UnitCreated, RecordUnit, "UnitCreated");
SafeAdd(GameEvents.UnitInitialized, RecordUnit, "UnitInitialized");

-- 脚本加载时先记录一次（新开游戏 / 读取存档）
-- ⚠ 必须 pcall：这是"主块"里的顶层调用，一旦抛错会**中断本文件后半段的所有注册**
--   （2026-10-03 实测：这里抛错 → 机位租借段整段没注册 → MaybeMoveBaseToPartnerTile 变 nil）
local okRecord, errRecord = pcall(RecordAllPlayers);
if not okRecord then
    Log("initial RecordAllPlayers failed: " .. tostring(errRecord));
end
Log("loaded");

-- ===========================================================================
-- 主动截击（2026-10-01 新增）：陆/海军防空单位可主动攻击射程内的敌方空军
-- ===========================================================================
-- 资格判定（与原版 CLASS_ANTI_AIR 语义一致，另含 CanTargetAir 的直升机等）：
--   非 DOMAIN_AIR 且（CanTargetAir 为真 或 AntiAirCombat > 0）
-- 攻击力：AntiAirCombat（防空战力 90~110）；为 0 时用 max(Combat, RangedCombat)
-- 射程：Units.Range，最小 1（近战型防空单位打相邻格飞机）
-- 伤害：原版战斗公式的期望值 Dmg = 30 * exp((攻-守)/25)，不掷随机（多人安全）
--   伤害>=50 时攻方战力按原版减员惩罚乘 0.65
-- 命中 +4 XP，击落共 +10 XP；开火后 FinishMoves 消耗本回合行动
-- 飞机不反击（地对空射击不构成对攻方的伤害交换）
local AA_DAMAGE_BASE = 30;
local AA_DAMAGE_TAU = 25;
local AA_MIN_DAMAGE = 5;
local AA_XP_HIT = 4;
local AA_XP_KILL_BONUS = 6;
local AA_WOUNDED_THRESHOLD = 50;
local AA_WOUNDED_FACTOR = 0.65;
local g_AACache = {};

local function ToFlag(v)
    return v == true or tonumber(v) == 1;
end

local function IsAAEligibleInfo(info)
    if info == nil then
        return false;
    end
    if info.Domain == "DOMAIN_AIR" then
        return false;
    end
    return ToFlag(info.CanTargetAir) or (tonumber(info.AntiAirCombat) or 0) > 0;
end

local function IsAAEligible(unit)
    if unit == nil then
        return false;
    end
    local t = unit:GetType();
    if g_AACache[t] == nil then
        g_AACache[t] = IsAAEligibleInfo(GameInfo.Units[t]);
    end
    return g_AACache[t];
end

local function GetAAStrength(unit)
    local info = GameInfo.Units[unit:GetType()];
    local aa = info ~= nil and (tonumber(info.AntiAirCombat) or 0) or 0;
    local str;
    if aa > 0 then
        str = aa;
    else
        local combat = info ~= nil and (tonumber(info.Combat) or 0) or 0;
        local ranged = info ~= nil and (tonumber(info.RangedCombat) or 0) or 0;
        str = math.max(combat, ranged);
    end
    -- 与面板“防空力量”显示对齐：军团 +7 / 军队 +15（同源能力修正）
    local f = GetProp(unit, AIR_FORMATION_KEY) or 0;
    if f == 1 then
        str = str + 7;
    elseif f >= 2 then
        str = str + 15;
    end
    if (unit:GetDamage() or 0) >= AA_WOUNDED_THRESHOLD then
        str = str * AA_WOUNDED_FACTOR;
    end
    return str;
end

-- 射程特调：防空炮 2 格、防空导弹车（机动防空）3 格；其余按 Units.Range 最小 1
local AA_RANGE_OVERRIDE = {
    UNIT_ANTIAIR_GUN = 2,
    UNIT_MOBILE_SAM  = 3,
};
local function GetAARangeByInfo(info)
    if info ~= nil then
        local ov = AA_RANGE_OVERRIDE[info.UnitType];
        if ov ~= nil then return ov end
    end
    return math.max(tonumber(info ~= nil and info.Range or 0) or 0, 1);
end

SafeAdd(GameEvents.BetterAirAAAttack, function(playerId, params)
    if params == nil or params.AttackerID == nil or params.TargetUnitID == nil or params.TargetPlayer == nil then
        return;
    end
    local attacker = UnitManager.GetUnit(playerId, params.AttackerID);
    if attacker == nil or not IsAAEligible(attacker) then
        Log("aa: attacker invalid, skip");
        return;
    end
    if attacker:GetMovesRemaining() <= 0 then
        Log("aa: no moves, skip");
        return;
    end

    local target = UnitManager.GetUnit(params.TargetPlayer, params.TargetUnitID);
    if target == nil then
        Log("aa: target gone, skip");
        return;
    end
    if not IsAirUnit(target) then
        Log("aa: target is not aircraft, skip");
        return;
    end
    if target:GetOwner() == playerId then
        return;
    end
    if attacker:GetX() < 0 or attacker:GetY() < 0 or target:GetX() < 0 or target:GetY() < 0 then
        Log("aa: bad coords, skip");
        return;
    end

    -- 交战校验：IsAtWarWith 在 UI 上下文有先例（CityStates.lua），gameplay 用 pcall 防不支持
    local okDip, atWar = pcall(function()
        local dip = Players[playerId]:GetDiplomacy();
        return dip ~= nil and dip:IsAtWarWith(params.TargetPlayer);
    end);
    if okDip and not atWar then
        -- 蛮族 territory：理论上 IsAtWarWith(蛮族) 为 true，这里是真和平目标，拒止
        Log(string.format("aa: not at war with p=%d, skip", params.TargetPlayer));
        return;
    end
    if not okDip then
        Log("aa: diplomacy check unavailable, allow without war check");
    end

    local dist = Map.GetPlotDistance(attacker:GetX(), attacker:GetY(), target:GetX(), target:GetY());
    local range = GetAARangeByInfo(GameInfo.Units[attacker:GetType()]);
    if dist > range then
        Log(string.format("aa: out of range dist=%d range=%d, skip", dist, range));
        return;
    end

    local attStr = GetAAStrength(attacker);
    local defStr = 0;
    local okCombat, live = pcall(function() return target:GetCombat() end);
    if okCombat and live ~= nil and live > 0 then
        defStr = live;
    else
        local info = GameInfo.Units[target:GetType()];
        defStr = tonumber(info and info.Combat) or 60;
    end
    if defStr <= 0 then
        defStr = 60;
    end

    local dmg = math.floor(AA_DAMAGE_BASE * math.exp((attStr - defStr) / AA_DAMAGE_TAU) + 0.5);
    if dmg < AA_MIN_DAMAGE then
        dmg = AA_MIN_DAMAGE;
    end

    local curDmg = target:GetDamage() or 0;
    local hpBefore = 100 - curDmg;
    local killed = false;
    if dmg >= hpBefore then
        killed = true;
        UnitManager.Kill(target);
    else
        local okChange = pcall(target.ChangeDamage, target, dmg);
        if not okChange then
            Log("aa: ChangeDamage failed, skip");
            return;
        end
    end

    local xp = AA_XP_HIT + (killed and AA_XP_KILL_BONUS or 0);
    pcall(function()
        local exp = attacker:GetExperience();
        if exp ~= nil then
            exp:ChangeExperience(xp);
        end
    end);
    UnitManager.FinishMoves(attacker);

    Log(string.format("aa fire p=%d u=%d(%d,%d) -> plane p=%d u=%d(%d,%d) dist=%d str=%.1f/%.1f dmg=%d killed=%s xp=%d",
        playerId, attacker:GetID(), attacker:GetX(), attacker:GetY(),
        params.TargetPlayer, target:GetID(), target:GetX(), target:GetY(),
        dist, attStr, defStr, dmg, tostring(killed), xp));
end, "BetterAirAAAttack");


-- ===========================================================================
-- 机位租借（2026-10-02 新增）：可以把飞机部署到签约伙伴玩家的
-- 航空港 / 市中心 / 跑道（航空港区域相邻格），以及在此基础上返还锚点。
-- ===========================================================================
-- 状态放在 PlayerProperties（同步进存档；UI 上下文读得到同一份组件）：
--   BetterAir_RentReq   ：玩家 P 的第 j 位 = P 正在请求租用玩家 j 的机位
--   BetterAir_RentGrant ：玩家 P 的第 j 位 = P 已开放机位给玩家 j 使用
-- 授予时机：P2 客户端与“曾向我请求机位的 P1”成交任意交易时（UI 中继 enacted）。
-- 使用权判定：CanRentLandAt(playerId, x, y) —— 自己地块恒真；他人地块要求
--   地块所有者存活、双方不处于战争、对方 Grant 位指向自己、且该格是
--   对方城市的市中心 / 航空港区域（含跑道，半径1近似）。
local RENT_REQ_KEY = "BetterAir_RentReq";
local RENT_GRANT_KEY = "BetterAir_RentGrant";

local function RentBitGet(mask, i)
    if mask == nil or i == nil or i < 0 then return false end
    mask = math.floor(tonumber(mask) or 0)
    return math.floor(mask / 2^i) % 2 == 1
end

local function RentBitSet(mask, i, on)
    mask = math.floor(tonumber(mask) or 0)
    if RentBitGet(mask, i) then
        if on then return mask else return mask - 2^i end
    else
        if on then return mask + 2^i else return mask end
    end
end

local function RentGetMask(playerObjOrID, key)
    local p = playerObjOrID
    if type(p) == "number" then p = Players[p] end
    if p == nil then return 0 end
    -- 修复：Players[] 全槽位扫描里会大量命中"未存活/未初始化"的槽位，
    -- 对它们读属性容器会踩到引擎的共享 GetProperty 绑定（崩溃点 0x1533e）
    if not PlayerAlive(p) then
        if TRACE_PROPS and type(playerObjOrID) == "number" then
            PropTrace(string.format("[BetterAirUnits] TRACE RentGetMask skip non-alive slot p=%d key=%s",
                playerObjOrID, tostring(key)));
        end
        return 0
    end
    local ok, v = pcall(function() return GetProp(p, key) end)
    if not ok or v == nil then return 0 end
    return math.floor(tonumber(v) or 0)
end

local function RentSetMask(playerObjOrID, key, mask)
    local p = playerObjOrID
    if type(p) == "number" then p = Players[p] end
    if p == nil then return end
    if not PlayerAlive(p) then
        if TRACE_PROPS and type(playerObjOrID) == "number" then
            PropTrace(string.format("[BetterAirUnits] TRACE RentSetMask skip non-alive slot p=%d key=%s",
                playerObjOrID, tostring(key)));
        end
        return
    end
    local ok, err = pcall(function() SetProp(p, key, math.floor(mask or 0)) end)
    if not ok then
        Log(string.format("rent: SetProperty %s failed: %s", key, tostring(err)))
    end
end

local function RentNotAtWar(aId, bId)
    local pa = Players[aId]
    local pb = Players[bId]
    if pa == nil or pb == nil then return false end
    -- 首选：GetDiplomaticStateID 对比 DIPLOSTATE_WAR（可靠 API）
    local warIdx = nil
    pcall(function()
        local row = GameInfo.DiplomaticStates["DIPLOSTATE_WAR"]
        if row ~= nil then warIdx = row.Index end
    end)
    local state = nil
    pcall(function() state = pa:GetDiplomacy():GetDiplomaticStateID(bId) end)
    if state ~= nil and warIdx ~= nil then
        return state ~= warIdx
    end
    -- 次选：IsAtWarWith（注意有的版本签名报错，报错不能再当“交战”处理）
    local ok, war = pcall(function() return pa:GetDiplomacy():IsAtWarWith(bId) end)
    if ok and war ~= nil then return not war end
    Log(string.format("rent: war state unreadable p=%d vs p=%d, treat as not-at-war", aId, bId))
    return true
end

local AERODROME_DISTRICT_INDEX = nil
local function GetAerodromeIndex()
    if AERODROME_DISTRICT_INDEX ~= nil then return AERODROME_DISTRICT_INDEX end
    local row = nil
    pcall(function() row = GameInfo.Districts["DISTRICT_AERODROME"] end)
    AERODROME_DISTRICT_INDEX = (row ~= nil) and row.Index or -2
    return AERODROME_DISTRICT_INDEX
end

-- 指定格是否是 ownerP 的可进驻机场格（市中心 / 航空港区域及相邻跑道格）
-- ⚠ 2026-10-03 重写：原来用 city:GetDistricts()/player:GetDistricts()，
--   但 **gameplay 上下文里这些方法不存在**（日志 26 次
--   "BetterAirUnits.lua:1281: function expected instead of nil"），
--   导致 CanRentLandAt 恒假 → 授权了也搬不了基地、也没有高亮。
--   改成只用 CvPlot 的绑定（两个上下文都有）：
--     plot:GetOwner() / plot:IsCity() / plot:GetDistrictType()
local function PlotIsCityCenter(plot)
    if plot == nil then return false end
    -- 首选 CvPlot:IsCity()；万一该版本没有，退回"区域类型 == 市中心"
    local c = false
    pcall(function() c = plot:IsCity() end)
    if c == true then return true end
    local ccIdx = nil
    pcall(function()
        local row = GameInfo.Districts["DISTRICT_CITY_CENTER"]
        if row ~= nil then ccIdx = row.Index end
    end)
    if ccIdx ~= nil then
        local dt = -1
        local ok = pcall(function() dt = plot:GetDistrictType() end)
        if ok and dt == ccIdx then return true end
    end
    return false
end

-- 飞机跑道 = 简易机场改良格（Improvements.AirSlots=3）。
-- 用户明确：市中心 / 航空港 / 飞机跑道 三者是"连在一起的机场"，都能提供机位，
-- 都属于可进驻的基地格。（注意：**不是**"航空港旁边随便一格"，那种错误扩张已删除。）
local AIRSTRIP_IMPROVEMENT_INDEX = nil
local function GetAirstripIndex()
    if AIRSTRIP_IMPROVEMENT_INDEX ~= nil then return AIRSTRIP_IMPROVEMENT_INDEX end
    local row = nil
    pcall(function() row = GameInfo.Improvements["IMPROVEMENT_AIRSTRIP"] end)
    AIRSTRIP_IMPROVEMENT_INDEX = (row ~= nil) and row.Index or -2
    return AIRSTRIP_IMPROVEMENT_INDEX
end

local function PlotIsAirstrip(plot)
    if plot == nil then return false end
    local idx = GetAirstripIndex()
    if idx == nil or idx < 0 then return false end
    local imp = -1
    local ok = pcall(function() imp = plot:GetImprovementType() end)
    return ok and imp == idx
end

local function PlotIsAerodrome(plot, aerIdx)
    if plot == nil or aerIdx == nil or aerIdx < 0 then return false end
    local dt = -1
    local ok = pcall(function() dt = plot:GetDistrictType() end)
    return ok and dt == aerIdx
end

-- ownerId：地块所有者的玩家号（调用方已读过一遍，避免重复 pcall）
local function IsPartnerBaseTile(x, y, ownerP, ownerId)
    if ownerP == nil then return false end
    local plot = Map.GetPlot(x, y)
    if plot == nil then return false end
    local plotOwner = -1
    pcall(function() plotOwner = plot:GetOwner() end)
    if ownerId ~= nil and plotOwner ~= ownerId then return false end   -- 必须是他家的地

    -- 1) 市中心
    if PlotIsCityCenter(plot) then return true end

    -- 2) 航空港区域格
    local aerIdx = GetAerodromeIndex()
    if PlotIsAerodrome(plot, aerIdx) then return true end
    -- 3) 飞机跑道（简易机场改良）格
    if PlotIsAirstrip(plot) then return true end
    return false
end

--  playerId 的飞机能否把基地落到 (x,y)？自己的地块恒真；他人地块需租借授权
CanRentLandAt = function(playerId, x, y)
    local plot = Map.GetPlot(x, y)
    if plot == nil then return false end
    local owner = -1
    pcall(function() owner = plot:GetOwner() end)
    if owner == playerId then return true end
    if owner == nil or owner < 0 then return false end
    local ownerP = Players[owner]
    if ownerP == nil or not ownerP:IsAlive() then return false end
    -- 战争期间租借暂停（和平自动恢复）；判定用 GetDiplomaticStateID，读不到按未交战放行
    if not RentNotAtWar(playerId, owner) then
        Log(string.format("rent: suspended by war p=%d vs host p=%d at (%d,%d)", playerId, owner, x, y))
        return false
    end
    if not RentBitGet(RentGetMask(ownerP, RENT_GRANT_KEY), playerId) then
        Log(string.format("rent: no grant from p=%d for p=%d at (%d,%d)", owner, playerId, x, y))
        return false
    end
    local hit = IsPartnerBaseTile(x, y, ownerP, owner)
    if not hit then
        Log(string.format("rent: (%d,%d) not a base tile of p=%d", x, y, owner))
    end
    return hit
end

-- 把“哪些伙伴把机位授权给了我”镜像写进该玩家每架飞机的 unit 属性。
-- UI 上下文要判断“这块地能不能进驻”，读 unit 属性是实测可靠的通道；
-- Player:GetProperty 在 UI 侧没有可靠先例，热座镜像缓存还会掩盖读不到的事实。
local RENT_HOSTS_KEY = "BetterAir_RentHosts"
RentSyncHostMasks = function()
    g_PropTraceBudget = 20;
    for pid = 0, GameDefines.MAX_PLAYERS - 1 do
        local p = Players[pid]
        if p ~= nil and p:IsAlive() and not p:IsBarbarian() then
            local hosts = 0
            for h = 0, GameDefines.MAX_PLAYERS - 1 do
                if h ~= pid then
                    local hp = Players[h]
                    if hp ~= nil and RentBitGet(RentGetMask(hp, RENT_GRANT_KEY), pid) then
                        hosts = RentBitSet(hosts, h, true)
                    end
                end
            end
            local mine = RentGetMask(p, RENT_REQ_KEY)
            pcall(function()
                for _, unit in p:GetUnits():Members() do
                    if IsAirUnit(unit) then
                        if (GetProp(unit, RENT_HOSTS_KEY) or 0) ~= hosts then
                            SetProp(unit, RENT_HOSTS_KEY, hosts)
                        end
                        if (GetProp(unit, "BetterAir_RentReq") or 0) ~= mine then
                            SetProp(unit, "BetterAir_RentReq", mine)
                        end
                    end
                end
            end)
        end
    end
end

-- UI 中继：BetterAirRentOp {Op="req"/"revoke"/"rejectreq"/"enacted", Other=j, On=0/1}
SafeAdd(GameEvents.BetterAirRentOp, function(playerId, params)
    if params == nil or params.Other == nil then return end
    local otherId = tonumber(params.Other)
    if otherId == nil or otherId < 0 then return end
    local me = Players[playerId]
    local other = Players[otherId]
    if me == nil or other == nil then return end
    local op = params.Op

    if op == "req" then
        local mask = RentBitSet(RentGetMask(me, RENT_REQ_KEY), otherId, params.On == 1)
        RentSetMask(me, RENT_REQ_KEY, mask)
        Log(string.format("rent: req p=%d other=%d on=%s", playerId, otherId, tostring(params.On)))

    elseif op == "grant" then
        -- 机位所有者直接同意/收回（交易页“协议”列表点击）
        local on = params.On == 1
        RentSetMask(me, RENT_GRANT_KEY, RentBitSet(RentGetMask(me, RENT_GRANT_KEY), otherId, on))
        if on then
            RentSetMask(other, RENT_REQ_KEY, RentBitSet(RentGetMask(other, RENT_REQ_KEY), playerId, false))
        end
        Log(string.format("rent: GRANT p=%d -> to=%d on=%s", playerId, otherId, tostring(on)))

    elseif op == "revoke" then
        local mask = RentBitSet(RentGetMask(me, RENT_GRANT_KEY), otherId, false)
        RentSetMask(me, RENT_GRANT_KEY, mask)
        Log(string.format("rent: revoked grant p=%d -> to=%d", playerId, otherId))

    elseif op == "rejectreq" then
        local mask = RentBitSet(RentGetMask(other, RENT_REQ_KEY), playerId, false)
        RentSetMask(other, RENT_REQ_KEY, mask)
        Log(string.format("rent: rejected request from p=%d (by=%d)", otherId, playerId))

    elseif op == "enacted" then
        -- 我与 other 成交；若 other 曾请求我的机位，则我此刻同意开放
        local reqMask = RentGetMask(other, RENT_REQ_KEY)
        if RentBitGet(reqMask, playerId) then
            RentSetMask(me, RENT_GRANT_KEY, RentBitSet(RentGetMask(me, RENT_GRANT_KEY), otherId, true))
            RentSetMask(other, RENT_REQ_KEY, RentBitSet(reqMask, playerId, false))
            Log(string.format("rent: GRANT p=%d -> to=%d (deal enacted)", playerId, otherId))
        end
    end
    pcall(RentSyncHostMasks)
end, "BetterAirRentOp");

-- 落点后把基地锚点迁到伙伴机场（仅当格属他人且授权有效）
MaybeMoveBaseToPartnerTile = function(playerId, unit, x, y)
    local plot = Map.GetPlot(x, y)
    if plot == nil then return end
    local owner = -1
    pcall(function() owner = plot:GetOwner() end)
    if owner == playerId or owner == nil or owner < 0 then return end
    if not CanRentLandAt(playerId, x, y) then return end
    SetProp(unit, AIR_BASE_X_KEY, x)
    SetProp(unit, AIR_BASE_Y_KEY, y)
    Log(string.format("rent: base moved p=%d u=%d -> (%d,%d) host=%d", playerId, unit:GetID(), x, y, owner))
end

-- 锚点守卫：REBASE/中继改写锚点后，若新锚点在他人地块而无租借授权，回滚
RentGuardAnchor = function(playerId, unit, oldBX, oldBY)
    local bx = GetProp(unit, AIR_BASE_X_KEY)
    local by = GetProp(unit, AIR_BASE_Y_KEY)
    if bx == nil or by == nil then return end
    local plot = Map.GetPlot(bx, by)
    if plot == nil then return end
    local owner = -1
    pcall(function() owner = plot:GetOwner() end)
    if owner == playerId then return end
    if CanRentLandAt(playerId, bx, by) then return end
    if oldBX ~= nil and oldBY ~= nil then
        SetProp(unit, AIR_BASE_X_KEY, oldBX)
        SetProp(unit, AIR_BASE_Y_KEY, oldBY)
        Log(string.format("rent: anchor guarded p=%d u=%d back to (%d,%d)", playerId, unit:GetID(), oldBX, oldBY))
    end
end

-- 飞机站在“已授权”的伙伴机场格上，但锚点还在老家（引擎 REBASE 到脚下格会判无目标，
-- 用户就永远改不了基地）——直接把锚点认领到脚下格。
RentAdoptAnchor = function(playerId, unit)
    local x, y = unit:GetX(), unit:GetY()
    if x == nil or y == nil or x < 0 or y < 0 then return end
    local bx = GetProp(unit, AIR_BASE_X_KEY)
    local by = GetProp(unit, AIR_BASE_Y_KEY)
    if bx == x and by == y then return end
    if not CanRentLandAt(playerId, x, y) then return end
    SetProp(unit, AIR_BASE_X_KEY, x)
    SetProp(unit, AIR_BASE_Y_KEY, y)
    Log(string.format("rent: anchor adopted p=%d u=%d -> (%d,%d)", playerId, unit:GetID(), x, y))
end

-- 回合开始清账：锚点停在已失效伙伴地块的飞机，锚点收回当前位置
RentSweepAll = function()
    g_PropTraceBudget = 20;
    pcall(RentSyncHostMasks)
    for playerId = 0, GameDefines.MAX_PLAYERS - 1 do
        local p = Players[playerId]
        if p ~= nil and p:IsAlive() and not p:IsBarbarian() then
            pcall(function()
                for _, unit in p:GetUnits():Members() do
                    if IsAirUnit(unit) then
                        pcall(HealBaseAnchor, unit, "turn-sweep")
                        pcall(RentAdoptAnchor, playerId, unit)
                        local bx = GetProp(unit, AIR_BASE_X_KEY)
                        local by = GetProp(unit, AIR_BASE_Y_KEY)
                        if bx ~= nil and by ~= nil then
                            local plot = Map.GetPlot(bx, by)
                            local owner = -1
                            pcall(function() owner = plot:GetOwner() end)
                            if plot ~= nil and owner ~= playerId and owner >= 0 then
                                if not CanRentLandAt(playerId, bx, by) then
                                    SetProp(unit, AIR_BASE_X_KEY, unit:GetX())
                                    SetProp(unit, AIR_BASE_Y_KEY, unit:GetY())
                                    Log(string.format("rent: anchor revoked p=%d u=%d -> (%d,%d)",
                                        playerId, unit:GetID(), unit:GetX(), unit:GetY()))
                                end
                            end
                        end
                    end
                end
            end)
        end
    end
end

Log("rent section loaded");
