-- BetterAirUnitsUnitPanel.lua
-- 通过 ReplaceUIScript 成为 UnitPanel 上下文的入口脚本。
-- 先加载和而不同（若启用）以及原版 UnitPanel 链，
-- 然后让“部署”（DEPLOY）按钮对还有移动力的飞机始终可用：
-- 自由飞行可能超出引擎射程，引擎会把按钮判灰，这里绕开。
local okDL = pcall(include, "DL_UnitPanel");
if not okDL then
    include("UnitPanel");
end

local DEBUG = false;   -- 发布版：需要排障时改回 true

local function Log(msg)
    if DEBUG then
        print("[BetterAirUnitsUP] " .. msg);
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
        PropTrace(string.format("[BetterAirUnitsUP] GetProp BLOCKED obj=%s key=%s", PropTargetDesc(o), tostring(key)));
        return nil;
    end
    local ok, v = pcall(function() return t:GetProperty(key) end);
    if not ok then return nil; end
    return v;
end

local function SetProp(o, key, val)
    local t = PropTarget(o);
    if t == nil then
        PropTrace(string.format("[BetterAirUnitsUP] SetProp BLOCKED obj=%s key=%s", PropTargetDesc(o), tostring(key)));
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

local BASE_CanStartOperation = UnitManager.CanStartOperation;
local BASE_CanStartCommand = UnitManager.CanStartCommand;

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

-- 主动截击资格（与 Scripts/BetterAirUnits.lua 中同规则）：
-- 非空军，且 CanTargetAir 或 AntiAirCombat>0（原版 CLASS_ANTI_AIR 集合 + 直升机）
local function ToFlag(v)
    return v == true or tonumber(v) == 1;
end

local function IsAAEligibleInfo(info)
    if info == nil or info.Domain == "DOMAIN_AIR" then
        return false;
    end
    return ToFlag(info.CanTargetAir) or (tonumber(info.AntiAirCombat) or 0) > 0;
end

function UnitManager.CanStartOperation(unit, operationType, ...)
    if (operationType == UnitOperationTypes.DEPLOY or operationType == UnitOperationTypes.REBASE) and unit ~= nil then
        local unitInfo = GameInfo.Units[unit:GetType()];
        local moves = unit:GetMovesRemaining();
        Log(string.format("deploy check u=%d moves=%d air=%s op=%s",
            unit:GetID(), moves, tostring(unitInfo ~= nil and unitInfo.Domain == "DOMAIN_AIR"),
            operationType == UnitOperationTypes.REBASE and "rebase" or "deploy"));
        if unitInfo ~= nil and unitInfo.Domain == "DOMAIN_AIR" then
            if moves > 0 then
                return true, {};
            end
            return false, {};
        end
    end

    -- 防空单位的“远程攻击”按钮：原版宽松检查直接判“此类单位永远不能攻击”，
    -- 按钮根本不显示。这里仅在引擎说不行时放行，显示“攻击”按钮；
    -- 目标筛选/结算全部在 WorldInput + gameplay 自定义管线里做。
    if operationType == UnitOperationTypes.RANGE_ATTACK and unit ~= nil then
        local unitInfo = GameInfo.Units[unit:GetType()];
        if IsAAEligibleInfo(unitInfo) and unit:GetMovesRemaining() > 0 then
            local baseOk = BASE_CanStartOperation(unit, operationType, ...);
            if not baseOk then
                Log(string.format("aa: force-enable RANGE_ATTACK u=%d", unit:GetID()));
                return true, {};
            end
        end
    end

    return BASE_CanStartOperation(unit, operationType, ...);
end

-- 引擎不允许空军编队、也不允许防空(支援)单位成军，这里强制显示“组建军团/军队”按钮，
-- 点击后由 WorldInput 里的自定义合并逻辑接管。
function UnitManager.CanStartCommand(unit, commandType, ...)
    if unit ~= nil then
        local unitInfo = GameInfo.Units[unit:GetType()];
        if unitInfo ~= nil
            and (unitInfo.Domain == "DOMAIN_AIR" or IsAAEligibleInfo(unitInfo))
            and (commandType == UnitCommandTypes.FORM_CORPS or commandType == UnitCommandTypes.FORM_ARMY) then
            local player = Players[unit:GetOwner()];
            local lv = 0;
            pcall(function() lv = tonumber(GetProp(unit, "BetterAir_Formation")) or 0 end);
            -- 先问引擎：海军之类原版本来就能成军的单位，一律按原版结果走，
            -- 我们只在“已经是军队(2)”时拦一道，绝不抢走原版按钮。
            local baseOk = BASE_CanStartCommand(unit, commandType, ...);
            if baseOk then
                if lv >= 2 then
                    return false, {};
                end
                return true, {};
            end
            -- 原版不允许（空军、支援类防空单位）：按我们的编队层级规则放行
            if lv >= 2 then
                return false, {};                      -- 军队是上限
            elseif commandType == UnitCommandTypes.FORM_CORPS then
                if lv == 0 and PlayerHasCivic(player, "CIVIC_MOBILIZATION") then
                    return true, {};                   -- 单机 → 军团
                end
            elseif commandType == UnitCommandTypes.FORM_ARMY then
                if lv == 1 and PlayerHasTech(player, "TECH_COMBINED_ARMS") then
                    return true, {};                   -- 军团 → 军队
                end
            end
            return false, {};
        end
    end
    return BASE_CanStartCommand(unit, commandType, ...);
end

Log("loaded");
