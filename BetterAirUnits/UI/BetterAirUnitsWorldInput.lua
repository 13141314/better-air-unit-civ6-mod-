-- BetterAirUnitsWorldInput.lua
-- 覆盖 WorldInput 上下文里的 DEPLOY 处理：
--   1) 高亮移动力范围内的所有格子（包括迷雾/敌方领土）；
--   2) 点击目标时直接通过 EXECUTE_SCRIPT 走自定义自由飞行
--      （绕过引擎 DEPLOY 的基地校验，避免改变基地后出现“新旧基地可部署范围交集”）。
-- 注意：只改 DEPLOY（部署/自由飞行）；REBASE（改变基地）保持原版，只能选跑道。

-- 本文件通过 ReplaceUIScript 成为 WorldInput 上下文的入口脚本。
-- 先加载和而不同（若启用）以及原版/扩展的 WorldInput 链，再覆盖相关函数。
local okHD = pcall(include, "HD_WorldInput");
if not okHD then
    local okExp2 = pcall(include, "WorldInput_Expansion2");
    if not okExp2 then
        include("WorldInput");
    end
end

local DEBUG = false;   -- 发布版：需要排障时改回 true

local function Log(msg)
    if DEBUG then
        print("[BetterAirUnitsWI] " .. msg);
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
        PropTrace(string.format("[BetterAirUnitsWI] GetProp BLOCKED obj=%s key=%s", PropTargetDesc(o), tostring(key)));
        return nil;
    end
    local ok, v = pcall(function() return t:GetProperty(key) end);
    if not ok then return nil; end
    return v;
end

local function SetProp(o, key, val)
    local t = PropTarget(o);
    if t == nil then
        PropTrace(string.format("[BetterAirUnitsWI] SetProp BLOCKED obj=%s key=%s", PropTargetDesc(o), tostring(key)));
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

-- ⚠ 前向声明：AirUnitReBase 在文件前段，而 CollectRentedBasePlots / IsAuthorizedPartnerTileUI
-- 定义在后段。Lua 的 local 作用域是"定义点之后"，不声明就会按**全局名**解析成 nil，
-- 实测报 "WorldInput.lua:248: function expected instead of nil" —— 点对方机场直接静默失败。
local CollectRentedBasePlots;
local IsAuthorizedPartnerTileUI;

local BASE_AirUnitDeploy = AirUnitDeploy;
local BASE_OnInterfaceModeChange_Deploy = OnInterfaceModeChange_Deploy;
local BASE_FormCorps = FormCorps;
local BASE_FormArmy = FormArmy;
local BASE_OnInterfaceModeChange_UnitFormCorps = OnInterfaceModeChange_UnitFormCorps;
local BASE_OnInterfaceModeChange_ReBase = OnInterfaceModeChange_ReBase;
local BASE_OnInterfaceModeChange_UnitFormArmy = OnInterfaceModeChange_UnitFormArmy;

local function IsAirUnit(unit)
    if unit == nil then
        return false;
    end
    local unitInfo = GameInfo.Units[unit:GetType()];
    return unitInfo ~= nil and unitInfo.Domain == "DOMAIN_AIR";
end

local function GetAirTargetPlots(unit, range)
    local plots = {};
    if unit == nil or range <= 0 then
        return plots;
    end
    local baseX = GetProp(unit, "BetterAir_BaseX");
    local baseY = GetProp(unit, "BetterAir_BaseY");
    -- 锚点不变量：基地离飞机不可能超过 maxMoves。超了就是过期锚点
    -- （用户报的"改基地到 X=15 后部署只能到 X=7"就是被旧基地的半径切掉）
    if baseX == nil or baseY == nil then
        baseX, baseY = unit:GetX(), unit:GetY();
    elseif Map.GetPlotDistance(baseX, baseY, unit:GetX(), unit:GetY()) > unit:GetMaxMoves() then
        Log(string.format("deploy hl: STALE anchor (%d,%d) dist=%d > max=%d -> use unit pos",
            baseX, baseY, Map.GetPlotDistance(baseX, baseY, unit:GetX(), unit:GetY()), unit:GetMaxMoves()));
        baseX, baseY = unit:GetX(), unit:GetY();
    end
    local baseRange = unit:GetMaxMoves();
    for _, plot in ipairs(Map.GetNeighborPlots(unit:GetX(), unit:GetY(), range)) do
        if Map.GetPlotDistance(baseX, baseY, plot:GetX(), plot:GetY()) <= baseRange then
            table.insert(plots, plot:GetIndex());
        end
    end
    return plots;
end

-- skipBaseCheck=true：改变基地（REBASE）只受“剩余移动力”限制。
-- 否则会出现：飞机已经飞到离旧基地 20 格外，再点任何地方都被“离旧基地太远”拒绝。
local function TryFlyTo(pSelectedUnit, tx, ty, operationType, opName, skipBaseCheck)
    local dist = Map.GetPlotDistance(pSelectedUnit:GetX(), pSelectedUnit:GetY(), tx, ty);
    if dist > pSelectedUnit:GetMovesRemaining() then
        Log(string.format("%s: out of range dist=%d moves=%d", opName, dist, pSelectedUnit:GetMovesRemaining()));
        return false;
    end
    local baseX = GetProp(pSelectedUnit, "BetterAir_BaseX");
    local baseY = GetProp(pSelectedUnit, "BetterAir_BaseY");
    if baseX == nil or baseY == nil then
        baseX, baseY = pSelectedUnit:GetX(), pSelectedUnit:GetY();
    elseif Map.GetPlotDistance(baseX, baseY, pSelectedUnit:GetX(), pSelectedUnit:GetY()) > pSelectedUnit:GetMaxMoves() then
        Log(string.format("%s: STALE anchor (%d,%d) -> use unit pos", opName, baseX, baseY));
        baseX, baseY = pSelectedUnit:GetX(), pSelectedUnit:GetY();
    end
    local baseDist = Map.GetPlotDistance(baseX, baseY, tx, ty);
    if not skipBaseCheck and baseDist > pSelectedUnit:GetMaxMoves() then
        Log(string.format("%s: beyond base range baseDist=%d max=%d", opName, baseDist, pSelectedUnit:GetMaxMoves()));
        return false;
    end

    local kParams = {
        OnStart = "BetterAirFreeFlight",
        UnitID = pSelectedUnit:GetID(),
        X = tx,
        Y = ty,
        Rebase = (operationType == UnitOperationTypes.REBASE) and 1 or nil,
    };
    UI.RequestPlayerOperation(pSelectedUnit:GetOwner(), PlayerOperations.EXECUTE_SCRIPT, kParams);
    Log(string.format("free flight relay %s u=%d -> (%d,%d) dist=%d", opName, pSelectedUnit:GetID(), tx, ty, dist));
    return true;
end

function AirUnitDeploy(pInputStruct)
    local plotID = UI.GetCursorPlotID();
    if not Map.IsPlot(plotID) then
        return true;
    end
    local plot = Map.GetPlotByIndex(plotID);
    local pSelectedUnit = UI.GetHeadSelectedUnit();
    if pSelectedUnit == nil then
        return true;
    end
    if not IsAirUnit(pSelectedUnit) then
        return BASE_AirUnitDeploy(pInputStruct);
    end

    if TryFlyTo(pSelectedUnit, plot:GetX(), plot:GetY(), UnitOperationTypes.DEPLOY, "deploy") then
        UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
    end
    return true;
end

function AirUnitReBase(pInputStruct)
    local plotID = UI.GetCursorPlotID();
    if not Map.IsPlot(plotID) then
        return true;
    end
    local plot = Map.GetPlotByIndex(plotID);
    local pSelectedUnit = UI.GetHeadSelectedUnit();
    if pSelectedUnit == nil then
        return true;
    end

    local tParameters = {};
    tParameters[UnitOperationTypes.PARAM_X] = plot:GetX();
    tParameters[UnitOperationTypes.PARAM_Y] = plot:GetY();
    if UnitManager.CanStartOperation(pSelectedUnit, UnitOperationTypes.REBASE, nil, tParameters) then
        UnitManager.RequestOperation(pSelectedUnit, UnitOperationTypes.REBASE, tParameters);
        local kParams = {
            OnStart = "ScenarioCommand_BetterAirRebaseComplete",
            UnitID = pSelectedUnit:GetID(),
            X = plot:GetX(),
            Y = plot:GetY(),
        };
        UI.RequestPlayerOperation(pSelectedUnit:GetOwner(), PlayerOperations.EXECUTE_SCRIPT, kParams);
        Log(string.format("rebase relay u=%d -> (%d,%d)", pSelectedUnit:GetID(), plot:GetX(), plot:GetY()));
        UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
        return true;
    end
    -- 引擎拒绝（迷雾/伙伴领土/超引擎射程等）：走自由飞行兜底
    -- ⚠ 别人的地必须先确认"仍持有授权" —— 之前这里完全没有校验，
    --   所以"收回同意租借后飞机照样能改基地过去"（实测日志：no grant 之后 free flight 仍成功）
    local tOwner = -1;
    pcall(function() tOwner = plot:GetOwner() end);
    if tOwner ~= nil and tOwner >= 0 and tOwner ~= pSelectedUnit:GetOwner() then
        if not IsAuthorizedPartnerTileUI(pSelectedUnit:GetOwner(), pSelectedUnit, plot:GetX(), plot:GetY()) then
            Log(string.format("rebase: foreign tile (%d,%d) owner=%d NOT authorized -> refused",
                plot:GetX(), plot:GetY(), tOwner));
            UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
            return true;
        end
        Log(string.format("rebase: foreign tile (%d,%d) owner=%d authorized -> free flight", plot:GetX(), plot:GetY(), tOwner));
    end
    if TryFlyTo(pSelectedUnit, plot:GetX(), plot:GetY(), UnitOperationTypes.REBASE, "rebase", true) then
        UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
        return true;
    end
    local rentedN = 0;
    pcall(function() rentedN = #CollectRentedBasePlots(pSelectedUnit:GetOwner(), pSelectedUnit) end);
    Log(string.format("rebase refused u=%d -> (%d,%d) moves=%d 授权可进驻格=%d（>0 表示授权已读到）",
        pSelectedUnit:GetID(), plot:GetX(), plot:GetY(), pSelectedUnit:GetMovesRemaining(), rentedN));
    UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
    return true;
end

local function HighlightAirRange(unit)
    local range = unit:GetMovesRemaining();
    Log(string.format("deploy hl center=(%d,%d) moves=%d", unit:GetX(), unit:GetY(), range));
    if range <= 0 then
        return;
    end
    local plots = GetAirTargetPlots(unit, range);
    g_targetPlots = plots;
    if table.count(plots) ~= 0 then
        local eLocalPlayer = Game.GetLocalPlayer();
        UILens.ToggleLayerOn(g_HexColoringMovement);
        UILens.SetLayerHexesArea(g_HexColoringMovement, eLocalPlayer, plots);
    end
end

-- ===========================================================================
-- 机位租借（UI 侧只读校验 + REBASE 左键接管）
-- 原版 REBASE 的左键走 OnMouseRebaseEnd，它只认引擎算出的 g_targetPlots（自家城市/机场），
-- 点伙伴地块会被静默丢弃 —— 这就是“同意了租借却改不了基地、而且什么日志都没有”的原因。
-- 这里把已授权伙伴的市中心/航空港/跑道并进可选格，并把左键直接接到我们的 AirUnitReBase。
-- ===========================================================================
local RENT_GRANT_KEY = "BetterAir_RentGrant";

local function RentBitGetUI(mask, i)
    return math.floor(mask / 2^i) % 2 == 1;
end

local function RentMaskUI(pid)
    local p = Players[pid];
    if p == nil then return 0 end
    -- 修复：UI 上下文里 Players[pid] 不保证是可读属性的对象，先判存活（详见文件顶部加固说明）
    if not PlayerAlive(p) then
        PropTrace(string.format("[BetterAirUnitsWI] TRACE RentMaskUI skip non-alive p=%s key=%s", tostring(pid), tostring(RENT_GRANT_KEY)));
        return 0
    end
    local ok, v = pcall(function() return GetProp(p, RENT_GRANT_KEY) end);
    if not ok or v == nil then return 0 end
    return math.floor(tonumber(v) or 0);
end

local function AerodromeIndexUI()
    local row = nil;
    pcall(function() row = GameInfo.Districts["DISTRICT_AERODROME"] end);
    return row ~= nil and row.Index or -2;
end

-- gameplay 侧会把“哪些伙伴授权给了我”镜像写进每架飞机的 unit 属性
-- （unit:GetProperty 在 UI 上下文可读是实测可靠的；Player:GetProperty 没有先例背书）
local function RentedHostMaskFromUnit(unit)
    if unit == nil then return nil end
    local v = nil;
    local ok = pcall(function() v = GetProp(unit, "BetterAir_RentHosts") end);
    if not ok or v == nil then return nil end
    return math.floor(tonumber(v) or 0);
end

-- 收集 meId 被授权进驻的所有格（伙伴玩家的市中心 + 航空港 + 相邻跑道格）
-- ⚠ 2026-10-03 重写：原来条件里用 `p:IsAlive()`，但**热座/UI 上下文里 Players[pid] 是 table**，
--   p:IsAlive() 在某些槽位会直接抛错 → 外层 pcall 一挂，整张列表变空
--   → 用户看到"授权了也没有高亮 / 授权格进不去"（实测日志：`授权可进驻格=0`）。
--   现在：PlayerAlive() 做安全解包；每个玩家单独 pcall，单点失败不影响其他人。
local function PlotIsCityCenterUI(plot)
    if plot == nil then return false end
    local c = false;
    pcall(function() c = plot:IsCity() end);
    return c == true;
end

local function PlotIsAerodromeUI(plot, aerIdx)
    if plot == nil or aerIdx == nil or aerIdx < 0 then return false end
    local dt = -1;
    local ok = pcall(function() dt = plot:GetDistrictType() end);
    return ok and dt == aerIdx;
end

-- 飞机跑道（简易机场改良）判定：市中心 / 航空港 / 跑道 三者都是"连在一起的机场"
local function PlotIsAirstripUI(plot)
    if plot == nil then return false end
    local idx = nil;
    pcall(function()
        local row = GameInfo.Improvements["IMPROVEMENT_AIRSTRIP"];
        if row ~= nil then idx = row.Index end
    end);
    if idx == nil then return false end
    local imp = -1;
    pcall(function() imp = plot:GetImprovementType() end);
    return imp == idx;
end

-- 在 (cx,cy) 半径 3 内找对方的跑道格（跑道总是贴着城市/机场，不用全图扫）
local function ScanAirstripsAround(cx, cy, ownerPid, AddPlot)
    if cx == nil or cy == nil then return end
    local okNb, nbs = pcall(Map.GetNeighborPlots, cx, cy, 3);
    if not okNb or nbs == nil then return end
    for _, nb in ipairs(nbs) do
        if nb ~= nil and PlotIsAirstripUI(nb) and nb:GetOwner() == ownerPid then AddPlot(nb) end
    end
end

CollectRentedBasePlots = function(meId, pUnit)
    local out = {};
    local seen = {};
    local aerIdx = AerodromeIndexUI();
    local function AddPlot(plot)
        if plot == nil then return end
        local idx = nil;
        pcall(function() idx = plot:GetIndex() end);
        if idx == nil or seen[idx] then return end
        seen[idx] = true;
        table.insert(out, idx);
    end
    local hostMask = RentedHostMaskFromUnit(pUnit);   -- 可能为 nil（老存档 / 新造飞机），退回扫描
    for pid = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        if pid ~= meId then
            local okOne, errOne = pcall(function()
                local p = Players[pid];
                if p == nil or not PlayerAlive(p) then return end
                local authorized;
                if hostMask ~= nil then authorized = RentBitGetUI(hostMask, pid)
                else authorized = RentBitGetUI(RentMaskUI(pid), meId) end
                if not authorized then return end
                Log(string.format("rent UI: host=%d AUTHORIZED (hostMask=%s uiMask=%s)",
                    pid, tostring(hostMask), tostring(RentMaskUI(pid))));
                local function ScanDistricts(districts, ownerPid)
                    if districts == nil then return end
                    for _, d in districts:Members() do
                        -- District:GetPlot() 在实测里不存在（原版 0 处使用），统一走 Map.GetPlot
                        local dp = nil;
                        if d ~= nil then
                            local okXY, dx, dy = pcall(function() return d:GetX(), d:GetY() end);
                            if okXY and dx ~= nil and dy ~= nil then dp = Map.GetPlot(dx, dy) end
                        end
                        -- 航空港本格 + 机场周边（≤3 格）的飞机跑道改良格
                        if dp ~= nil and d:GetType() == aerIdx then
                            AddPlot(dp);
                            ScanAirstripsAround(dp:GetX(), dp:GetY(), ownerPid, AddPlot);
                        end
                    end
                end
                for _, city in p:GetCities():Members() do
                    if city ~= nil then
                        -- City:GetPlot() 同样不存在；正确写法是 Map.GetPlot(city:GetX(), city:GetY())
                        local cpx, cpy = city:GetX(), city:GetY();
                        if cpx ~= nil and cpy ~= nil then
                            AddPlot(Map.GetPlot(cpx, cpy));
                            ScanAirstripsAround(cpx, cpy, pid, AddPlot);
                        end
                        local okD, districts = pcall(function() return city:GetDistricts() end);
                        if okD then ScanDistricts(districts, pid)
                        else Log("rent UI: city:GetDistricts failed, skip city districts") end
                    end
                end
                local okPD, pDistricts = pcall(function() return p:GetDistricts() end);
                if okPD then ScanDistricts(pDistricts, pid)
                else Log("rent UI: player:GetDistricts failed, skip player districts") end
            end);
            if not okOne then
                Log(string.format("rent UI: player %d collect failed: %s", pid, tostring(errOne)));
            end
        end
    end
    Log(string.format("rent UI: %d rented base tiles collected (hostMask=%s)", #out, tostring(hostMask)));
    return out;
end

-- UI 侧：目标格是不是"已授权给我的伙伴机场格"（撤销后立即失效）
IsAuthorizedPartnerTileUI = function(meId, pUnit, x, y)
    local plot = Map.GetPlot(x, y);
    if plot == nil then return false end
    local owner = -1;
    pcall(function() owner = plot:GetOwner() end);
    if owner == nil or owner < 0 then return false end
    if owner == meId then return true end
    local hostMask = RentedHostMaskFromUnit(pUnit);
    local authorized;
    if hostMask ~= nil then authorized = RentBitGetUI(hostMask, owner)
    else authorized = RentBitGetUI(RentMaskUI(owner), meId) end
    if not authorized then return false end
    if PlotIsCityCenterUI(plot) then return true end
    local aerIdx = AerodromeIndexUI();
    if PlotIsAerodromeUI(plot, aerIdx) then return true end
    if PlotIsAirstripUI(plot) then return true end
    return false;
end

local BASE_OnMouseRebaseEnd = OnMouseRebaseEnd;

function OnMouseRebaseEndUI(pInputStruct)
    if g_isMouseDragging then
        g_isMouseDragging = false;
    else
        AirUnitReBase(pInputStruct);
    end
    EndDragMap(true);
    g_isMouseDownInWorld = false;
    return true;
end

function OnInterfaceModeChange_ReBaseUI(eNewMode)
    Log("rebase ENTER");
    local pSelectedUnit = UI.GetHeadSelectedUnit();
    if pSelectedUnit == nil then return true end;
    local info = GameInfo.Units[pSelectedUnit:GetType()];
    if info == nil or info.Domain ~= "DOMAIN_AIR" then
        return BASE_OnInterfaceModeChange_ReBase(eNewMode);
    end
    UIManager:SetUICursor(CursorTypes.RANGE_ATTACK);
    local meId = pSelectedUnit:GetOwner();
    local moves = pSelectedUnit:GetMovesRemaining();
    if moves == nil or moves < 0 then moves = 0 end
    g_targetPlots = {};
    -- 1) 引擎自己认可的 REBASE 目标（自家城市/机场/航母）
    local ok, tResults = pcall(UnitManager.GetOperationTargets, pSelectedUnit, UnitOperationTypes.REBASE);
    if ok and tResults ~= nil and tResults[UnitOperationResults.PLOTS] ~= nil then
        for _, pidx in ipairs(tResults[UnitOperationResults.PLOTS]) do
            table.insert(g_targetPlots, pidx);
        end
    end
    -- 2) 租借授权格：只要飞得到（剩余移动力）就允许把基地改过去
    local added = 0;
    for _, pidx in ipairs(CollectRentedBasePlots(meId, pSelectedUnit)) do
        local plot = Map.GetPlotByIndex(pidx);
        if plot ~= nil and Map.GetPlotDistance(pSelectedUnit:GetX(), pSelectedUnit:GetY(), plot:GetX(), plot:GetY()) <= moves then
            table.insert(g_targetPlots, pidx);
            added = added + 1;
        end
    end
    Log(string.format("rebase hl: %d engine targets + %d rented base tiles (moves=%d)",
        #g_targetPlots - added, added, moves));
    if table.count(g_targetPlots) ~= 0 then
        UILens.ToggleLayerOn(g_HexColoringMovement);
        UILens.SetLayerHexesArea(g_HexColoringMovement, meId, g_targetPlots);
    end
    return true;
end

-- ⚠ 引擎是按"全局函数名"直接调用 OnInterfaceModeChange_<Mode> 的（Deploy 就是这么生效的）。
-- REBASE 之前只重绑了 InterfaceModeMessageHandler 的表项，实测 **ENTER 从没触发**
-- （日志里 rebase ENTER / rebase hl 各 0 次）→ 完全没有高亮 + 授权格进不了 g_targetPlots。
-- 这里改成和 Deploy 完全一样的做法：覆盖全局名。
function OnInterfaceModeChange_ReBase(eNewMode)
    return OnInterfaceModeChange_ReBaseUI(eNewMode);
end

function OnInterfaceModeChange_Deploy(eNewMode)
    local pSelectedUnit = UI.GetHeadSelectedUnit();
    if pSelectedUnit == nil or not IsAirUnit(pSelectedUnit) then
        return BASE_OnInterfaceModeChange_Deploy(eNewMode);
    end
    HighlightAirRange(pSelectedUnit);
end

local function RelayMerge(pSelectedUnit, pTarget)
    local kParams = {
        OnStart = "BetterAirMerge",
        LeaderID = pSelectedUnit:GetID(),
        AbsorbID = pTarget:GetID(),
    };
    UI.RequestPlayerOperation(pSelectedUnit:GetOwner(), PlayerOperations.EXECUTE_SCRIPT, kParams);
    Log(string.format("merge relay leader=%d absorb=%d", pSelectedUnit:GetID(), pTarget:GetID()));
end

-- 合并资格：空军（编队）或防空单位（军团/军队）；独立小实现，不依赖文件后段的 local
local g_BARMergeAACache = {};
local function IsAAUnitForMerge(u)
    if u == nil then
        return false;
    end
    local t = u:GetType();
    if g_BARMergeAACache[t] == nil then
        local info = GameInfo.Units[t];
        local ok = false;
        if info ~= nil and info.Domain ~= "DOMAIN_AIR" then
            local at = info.CanTargetAir;
            ok = (at == true or tonumber(at) == 1) or (tonumber(info.AntiAirCombat) or 0) > 0;
        end
        g_BARMergeAACache[t] = ok;
    end
    return g_BARMergeAACache[t];
end
local function CanMergeUnit(u)
    return IsAirUnit(u) or IsAAUnitForMerge(u)
end

-- 编队层级（gameplay 写在同一个属性键上）：0 单机 / 1 军团 / 2 军队
local function MergeLevel(u)
    if u == nil then return -1 end
    local v = nil
    pcall(function() v = GetProp(u, "BetterAir_Formation") end)
    return tonumber(v) or 0
end

-- gameplay 端接受的组合：{0,0}->军团；{1,0}或{0,1}->军队（自动把军团换到主机位）。
-- 军队(2)是上限，任何含 2 的组合、以及军团+军团都不行。
local function MergePairOK(a, b)
    if a < 0 or b < 0 then return false end
    if a == 0 and b == 0 then return true end
    if a == 1 and b == 0 then return true end
    if a == 0 and b == 1 then return true end
    return false
end

local function MergeTargetOnPlot(pInputStruct, isArmy)
    local pSelectedUnit = UI.GetHeadSelectedUnit();
    if pSelectedUnit == nil or not CanMergeUnit(pSelectedUnit) then
        return nil;
    end
    local plotID = UI.GetCursorPlotID();
    if not Map.IsPlot(plotID) then
        return nil;
    end
    local plot = Map.GetPlotByIndex(plotID);
    for _, pUnit in ipairs(Units.GetUnitsInPlotLayerID(plot:GetX(), plot:GetY(), MapLayers.ANY)) do
        if pUnit:GetID() ~= pSelectedUnit:GetID()
            and pUnit:GetOwner() == pSelectedUnit:GetOwner()
            and CanMergeUnit(pUnit)
            and pUnit:GetType() == pSelectedUnit:GetType()
            and MergePairOK(MergeLevel(pSelectedUnit), MergeLevel(pUnit)) then
            return pUnit;
        end
    end
    return nil;
end

local ClearFormationHighlight;

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

local function HasAirMergeUnlock(unit, isArmy)
    if unit == nil then
        return false;
    end
    local player = Players[unit:GetOwner()];
    if player == nil then
        return false;
    end
    if isArmy then
        return PlayerHasTech(player, "TECH_COMBINED_ARMS");
    end
    return PlayerHasCivic(player, "CIVIC_MOBILIZATION");
end

function FormCorps(pInputStruct)
    local pSelectedUnit = UI.GetHeadSelectedUnit();
    if pSelectedUnit ~= nil and CanMergeUnit(pSelectedUnit) then
        if not HasAirMergeUnlock(pSelectedUnit, false) then
            Log("form corps: requires CIVIC_MOBILIZATION");
            return true;
        end
        local pTarget = MergeTargetOnPlot(pInputStruct, false);
        if pTarget ~= nil then
            RelayMerge(pSelectedUnit, pTarget);
            ClearFormationHighlight();
            UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
            return true;
        end
        Log(string.format("form corps: 脚下没有合法目标（我方等级=%d，军队是上限，军团不能并军团）", MergeLevel(pSelectedUnit)));
        return true;
    end
    return BASE_FormCorps(pInputStruct);
end

function FormArmy(pInputStruct)
    local pSelectedUnit = UI.GetHeadSelectedUnit();
    if pSelectedUnit ~= nil and CanMergeUnit(pSelectedUnit) then
        if not HasAirMergeUnlock(pSelectedUnit, true) then
            Log("form army: requires TECH_COMBINED_ARMS");
            return true;
        end
        local pTarget = MergeTargetOnPlot(pInputStruct, true);
        if pTarget ~= nil then
            RelayMerge(pSelectedUnit, pTarget);
            ClearFormationHighlight();
            UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
            return true;
        end
        Log(string.format("form army: 脚下没有合法目标（我方等级=%d，只有 军团+单机 能升军队）", MergeLevel(pSelectedUnit)));
        return true;
    end
    return BASE_FormArmy(pInputStruct);
end

local function HighlightFormationTargets(unit)
    if unit == nil or not CanMergeUnit(unit) then
        return;
    end
    local x, y = unit:GetX(), unit:GetY();
    local plots = {};
    local seen = {};
    local function AddCandidate(plot)
        if plot == nil or seen[plot:GetIndex()] then
            return;
        end
        seen[plot:GetIndex()] = true;
        for _, pUnit in ipairs(Units.GetUnitsInPlotLayerID(plot:GetX(), plot:GetY(), MapLayers.ANY)) do
            if pUnit:GetID() ~= unit:GetID()
                and pUnit:GetOwner() == unit:GetOwner()
                and CanMergeUnit(pUnit)
                and pUnit:GetType() == unit:GetType()
                and MergePairOK(MergeLevel(unit), MergeLevel(pUnit)) then
                table.insert(plots, plot:GetIndex());
                break;
            end
        end
    end
    AddCandidate(Map.GetPlot(x, y));
    for _, plot in ipairs(Map.GetNeighborPlots(x, y, 1)) do
        AddCandidate(plot);
    end
    g_targetPlots = plots;
    if table.count(plots) ~= 0 then
        local eLocalPlayer = Game.GetLocalPlayer();
        UILens.ToggleLayerOn(g_HexColoringMovement);
        UILens.SetLayerHexesArea(g_HexColoringMovement, eLocalPlayer, plots);
    end
end

ClearFormationHighlight = function()
    if UILens ~= nil and g_HexColoringMovement ~= nil then
        UILens.ClearLayerHexes(g_HexColoringMovement);
    end
    if UILens ~= nil and g_HexColoringPlacement ~= nil then
        UILens.ClearLayerHexes(g_HexColoringPlacement);
    end
    g_targetPlots = {};
end

-- 原版 OnInterfaceModeLeave_UnitFormCorps/Army 只清 Placement 层；
-- 我们的合并高亮画在 Movement 层上，必须在这里补一次清理，否则绿光会留在地图上。
local BASE_OnInterfaceModeLeave_UnitFormCorps = OnInterfaceModeLeave_UnitFormCorps;
local BASE_OnInterfaceModeLeave_UnitFormArmy  = OnInterfaceModeLeave_UnitFormArmy;

function OnInterfaceModeLeave_UnitFormCorps(eNewMode)
    ClearFormationHighlight();
    if BASE_OnInterfaceModeLeave_UnitFormCorps ~= nil then
        BASE_OnInterfaceModeLeave_UnitFormCorps(eNewMode);
    end
end

function OnInterfaceModeLeave_UnitFormArmy(eNewMode)
    ClearFormationHighlight();
    if BASE_OnInterfaceModeLeave_UnitFormArmy ~= nil then
        BASE_OnInterfaceModeLeave_UnitFormArmy(eNewMode);
    end
end

function OnInterfaceModeChange_UnitFormCorps(eNewMode)
    local pSelectedUnit = UI.GetHeadSelectedUnit();
    if pSelectedUnit ~= nil and CanMergeUnit(pSelectedUnit) and MergeLevel(pSelectedUnit) >= 2 then
        Log("form corps refused: 已是军队（上限），不能再合并");
        pcall(function() UI.SetInterfaceMode(InterfaceModeTypes.SELECTION); end);
        return;
    end
    if pSelectedUnit ~= nil and CanMergeUnit(pSelectedUnit) then
        local unlocked = HasAirMergeUnlock(pSelectedUnit, false);
        Log(string.format("form corps mode: unlock=%s", tostring(unlocked)));
        if unlocked then
            HighlightFormationTargets(pSelectedUnit);
        end
        return;
    end
    return BASE_OnInterfaceModeChange_UnitFormCorps(eNewMode);
end

function OnInterfaceModeChange_UnitFormArmy(eNewMode)
    local pSelectedUnit = UI.GetHeadSelectedUnit();
    if pSelectedUnit ~= nil and CanMergeUnit(pSelectedUnit) and MergeLevel(pSelectedUnit) >= 2 then
        Log("form army refused: 已是军队（上限），不能再合并");
        pcall(function() UI.SetInterfaceMode(InterfaceModeTypes.SELECTION); end);
        return;
    end
    if pSelectedUnit ~= nil and CanMergeUnit(pSelectedUnit) then
        local unlocked = HasAirMergeUnlock(pSelectedUnit, true);
        Log(string.format("form army mode: unlock=%s", tostring(unlocked)));
        if unlocked then
            HighlightFormationTargets(pSelectedUnit);
        end
        return;
    end
    return BASE_OnInterfaceModeChange_UnitFormArmy(eNewMode);
end

-- ===========================================================================
-- 主动截击（2026-10-01 新增）：陆/海军防空单位的“攻击”模式目标改为敌方空军
--   - RealizeTargetPlots：引擎说“没有目标”，这里自己高亮射程内的敌方飞机
--   - UnitRangeAttack：点击飞机所在格时走 EXECUTE_SCRIPT 让 gameplay 结算
--   - RequestMoveOperation：右击敌方飞机直接开火
-- 这三个函数在原版里都是“运行时按全局名查找”调用（见 WorldInput.lua
-- OnInterfaceModeChange_UnitRangeAttack / OnMouseUnitRangeAttack 与
-- Civ6Common.lua），所以覆盖全局即可生效，无需重绑事件表。
-- ===========================================================================
local g_AACacheUI = {};

local function ToFlag(v)
    return v == true or tonumber(v) == 1;
end

local function IsAAEligibleInfo(info)
    if info == nil or info.Domain == "DOMAIN_AIR" then
        return false;
    end
    return ToFlag(info.CanTargetAir) or (tonumber(info.AntiAirCombat) or 0) > 0;
end

local function IsAAEligible(unit)
    if unit == nil then
        return false;
    end
    local t = unit:GetType();
    if g_AACacheUI[t] == nil then
        g_AACacheUI[t] = IsAAEligibleInfo(GameInfo.Units[t]);
    end
    return g_AACacheUI[t];
end

-- 射程特调（与 gameplay 端一致）：防空炮 2 格、机动防空(防空导弹车) 3 格
local AA_RANGE_OVERRIDE_UI = {
    UNIT_ANTIAIR_GUN = 2,
    UNIT_MOBILE_SAM  = 3,
};
local function GetAARange(unit)
    local info = GameInfo.Units[unit:GetType()];
    if info ~= nil then
        local ov = AA_RANGE_OVERRIDE_UI[info.UnitType];
        if ov ~= nil then
            return ov;
        end
    end
    local r = tonumber(info and info.Range) or 0;
    if r < 1 then
        r = 1;
    end
    return r;
end

-- 收集可打的目标：交战的别家空军、在本方（选中单位主人）视野内、距离 <= 射程
-- 注意坑（2026-10-01 实测，热座局刷屏 191 次）：
--   RefManager:Members() 是“双值迭代器”，返回 (索引, 单位)——必须写
--   for _, u in xxx:Members()；单变量会把索引数字绑成 u，
--   一调 u:GetType() 就是 "attempt to index a number value"。
--   （UnitList:Units() 那种才是单值迭代器，两个 API 语义不同。）
-- 整体再包一层 pcall：任何意外都不允许把玩家的点击/移动输入卡死。
local function CollectAAAirTargets(unit)
    local out = {};
    if unit == nil then
        return out;
    end
    local ok = pcall(function()
        local owner = unit:GetOwner();
        local range = GetAARange(unit);
        local px, py = unit:GetX(), unit:GetY();
        for iPlayer, pPlayer in ipairs(Players) do
            if iPlayer ~= owner and pPlayer ~= nil and pPlayer:GetUnits() ~= nil then
                local okDip, atWar = pcall(function()
                    local dip = Players[owner]:GetDiplomacy();
                    return dip ~= nil and dip:IsAtWarWith(iPlayer);
                end);
                if not okDip then
                    atWar = true;  -- 拿不到外交状态时不做过滤，gameplay 端还会再校验
                end
                if atWar then
                    for _, airUnit in pPlayer:GetUnits():Members() do
                        if airUnit ~= nil and (type(airUnit) == "table" or type(airUnit) == "userdata") then
                            local info = GameInfo.Units[airUnit:GetType()];
                            if info ~= nil and info.Domain == "DOMAIN_AIR"
                                and (airUnit:GetDamage() or 0) < 100
                                and airUnit:GetX() >= 0 and airUnit:GetY() >= 0 then
                                if Map.GetPlotDistance(px, py, airUnit:GetX(), airUnit:GetY()) <= range then
                                    local visible = true;
                                    if PlayersVisibility ~= nil then
                                        local okV, v = pcall(function()
                                            return PlayersVisibility[owner]:IsVisible(airUnit:GetX(), airUnit:GetY());
                                        end);
                                        visible = (not okV) or v;
                                    end
                                    if visible then
                                        local plot = Map.GetPlot(airUnit:GetX(), airUnit:GetY());
                                        if plot ~= nil then
                                            table.insert(out, {
                                                unit = airUnit,
                                                plotIndex = plot:GetIndex(),
                                                owner = iPlayer,
                                            });
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end);
    if not ok then
        Log("aa: CollectAAAirTargets internal error (degraded to no aircraft targets)");
    end
    return out;
end

local BASE_RealizeTargetPlots = RealizeTargetPlots;

-- 高亮 = 原版 RANGE_ATTACK 合法目标（战列舰等海军防空单位打陆地照样可用）
--        ∪ 射程内敌方飞机所在格。两类目标都画攻击弧。
function RealizeTargetPlots(pUnit)
    if pUnit ~= nil and IsAAEligible(pUnit) then
        local targets = CollectAAAirTargets(pUnit);
        local unitPlotID = pUnit:GetPlotId();
        local eLocal = Game.GetLocalPlayer();
        local allPlots = {};
        local variations = {};
        g_targetPlots = {};
        local ok, tResults = pcall(UnitManager.GetOperationTargets, pUnit, UnitOperationTypes.RANGE_ATTACK);
        if (not ok) or tResults == nil then
            -- 引擎查询失败：完全回退原版高亮，至少不破坏正常远程攻击
            if BASE_RealizeTargetPlots ~= nil then
                return BASE_RealizeTargetPlots(pUnit);
            end
            return;
        end
        if tResults[UnitOperationResults.PLOTS] ~= nil then
            local engAll = tResults[UnitOperationResults.PLOTS];
            local mods = tResults[UnitOperationResults.MODIFIERS] or {};
            for i, modifier in ipairs(mods) do
                local pidx = engAll[i];
                if pidx ~= nil and modifier == UnitOperationResults.MODIFIER_IS_TARGET then
                    table.insert(allPlots, pidx);
                    table.insert(g_targetPlots, pidx);
                    table.insert(variations, {"EmptyVariant", unitPlotID, pidx});
                end
            end
        end
        for _, t in ipairs(targets) do
            table.insert(allPlots, t.plotIndex);
            table.insert(g_targetPlots, t.plotIndex);
            table.insert(variations, {"EmptyVariant", unitPlotID, t.plotIndex});
        end
        if #allPlots ~= 0 then
            UILens.SetLayerHexesArea(g_AttackRange, eLocal, allPlots, variations);
        end
        Log(string.format("aa targets: %d planes + engine targets drawn", #targets));
        return;
    end
    if BASE_RealizeTargetPlots ~= nil then
        return BASE_RealizeTargetPlots(pUnit);
    end
end

local BASE_UnitRangeAttack = UnitRangeAttack;

function UnitRangeAttack(plotID)
    local pSelectedUnit = UI.GetHeadSelectedUnit();
    if pSelectedUnit ~= nil and IsAAEligible(pSelectedUnit) then
        local targets = CollectAAAirTargets(pSelectedUnit);
        for _, t in ipairs(targets) do
            if t.plotIndex == plotID then
                local plot = Map.GetPlotByIndex(plotID);
                local kParams = {
                    OnStart = "BetterAirAAAttack",
                    AttackerID = pSelectedUnit:GetID(),
                    TargetPlayer = t.owner,
                    TargetUnitID = t.unit:GetID(),
                    X = plot ~= nil and plot:GetX() or nil,
                    Y = plot ~= nil and plot:GetY() or nil,
                };
                UI.RequestPlayerOperation(pSelectedUnit:GetOwner(), PlayerOperations.EXECUTE_SCRIPT, kParams);
                Log(string.format("aa relay: u=%d fires at plane p=%d u=%d",
                    pSelectedUnit:GetID(), t.owner, t.unit:GetID()));
                UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
                return;
            end
        end
        -- 没点到飞机：回落到原版逻辑（支持点对陆地目标的海军防空单位，
        -- 也保持原版“点空地取消选中”的行为）
        if BASE_UnitRangeAttack ~= nil then
            return BASE_UnitRangeAttack(plotID);
        end
        UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
        return;
    end
    if BASE_UnitRangeAttack ~= nil then
        return BASE_UnitRangeAttack(plotID);
    end
end

-- 右击：Civ6Common.RequestMoveOperation 原版对防空单位无“打飞机”分支，这里补上
if RequestMoveOperation ~= nil then
    local BASE_RequestMoveOperation = RequestMoveOperation;
    function RequestMoveOperation(kUnit, tParameters, plotX, plotY)
        if kUnit ~= nil and IsAAEligible(kUnit) and plotX ~= nil and plotY ~= nil then
            local targets = CollectAAAirTargets(kUnit);
            for _, t in ipairs(targets) do
                local tp = Map.GetPlot(t.unit:GetX(), t.unit:GetY());
                if tp ~= nil and tp:GetX() == plotX and tp:GetY() == plotY then
                    local kParams = {
                        OnStart = "BetterAirAAAttack",
                        AttackerID = kUnit:GetID(),
                        TargetPlayer = t.owner,
                        TargetUnitID = t.unit:GetID(),
                        X = plotX,
                        Y = plotY,
                    };
                    UI.RequestPlayerOperation(kUnit:GetOwner(), PlayerOperations.EXECUTE_SCRIPT, kParams);
                    Log(string.format("aa right-click: u=%d fires at plane p=%d u=%d",
                        kUnit:GetID(), t.owner, t.unit:GetID()));
                    return;
                end
            end
        end
        return BASE_RequestMoveOperation(kUnit, tParameters, plotX, plotY);
    end
    Log("aa: RequestMoveOperation wrapped");
else
    Log("aa: RequestMoveOperation global not found; right-click path inactive");
end
Log("aa intercept hooks installed");

-- 原版在加载时已经把旧函数引用写进事件表，这里只重新绑定 DEPLOY 到我们的实现
if InterfaceModeMessageHandler ~= nil then
    local mDeploy = InterfaceModeMessageHandler[InterfaceModeTypes.DEPLOY];
    if mDeploy ~= nil then
        mDeploy[INTERFACEMODE_ENTER] = OnInterfaceModeChange_Deploy;
        mDeploy[MouseEvents.LButtonUp] = OnMouseDeployEnd;
        mDeploy[MouseEvents.PointerUp] = AirUnitDeploy;
    end
    local rebaseMode = (InterfaceModeTypes ~= nil) and InterfaceModeTypes.REBASE or nil;
    Log(string.format("rebind probe: InterfaceModeTypes=%s REBASE key=%s handler table=%s",
        tostring(InterfaceModeTypes ~= nil), tostring(rebaseMode),
        tostring(rebaseMode ~= nil and InterfaceModeMessageHandler[rebaseMode] ~= nil)));
    if rebaseMode ~= nil then
        if InterfaceModeMessageHandler[rebaseMode] == nil then
            InterfaceModeMessageHandler[rebaseMode] = {};
            Log("rebind: REBASE 槽位不存在，已补建");
        end
        local mRebase = InterfaceModeMessageHandler[rebaseMode];
        mRebase[INTERFACEMODE_ENTER] = OnInterfaceModeChange_ReBaseUI;
        mRebase[INTERFACEMODE_LEAVE] = OnInterfaceModeLeave_ReBase;
        mRebase[MouseEvents.LButtonUp] = OnMouseRebaseEndUI;
        mRebase[MouseEvents.PointerUp] = AirUnitReBase;
        Log(string.format("rebind done: REBASE enter=%s leave=%s lbtn=%s ptr=%s",
            tostring(mRebase[INTERFACEMODE_ENTER] ~= nil), tostring(mRebase[INTERFACEMODE_LEAVE] ~= nil),
            tostring(mRebase[MouseEvents.LButtonUp] ~= nil), tostring(mRebase[MouseEvents.PointerUp] ~= nil)));
    end
    local mFormCorps = InterfaceModeMessageHandler[InterfaceModeTypes.FORM_CORPS];
    local mFormArmy = InterfaceModeMessageHandler[InterfaceModeTypes.FORM_ARMY];
    if mFormCorps ~= nil then
        mFormCorps[INTERFACEMODE_ENTER] = OnInterfaceModeChange_UnitFormCorps;
        mFormCorps[INTERFACEMODE_LEAVE] = OnInterfaceModeLeave_UnitFormCorps;
        mFormCorps[MouseEvents.LButtonUp] = FormCorps;
        mFormCorps[MouseEvents.PointerUp] = FormCorps;
    end
    if mFormArmy ~= nil then
        mFormArmy[INTERFACEMODE_ENTER] = OnInterfaceModeChange_UnitFormArmy;
        mFormArmy[INTERFACEMODE_LEAVE] = OnInterfaceModeLeave_UnitFormArmy;
        mFormArmy[MouseEvents.LButtonUp] = FormArmy;
        mFormArmy[MouseEvents.PointerUp] = FormArmy;
    end
    -- 兜底：回到普通选中态时一律清掉我们的格子高亮（ESC、点空白、换单位等路径）
    local mSel = InterfaceModeMessageHandler[InterfaceModeTypes.SELECTION];
    if mSel ~= nil and mSel[INTERFACEMODE_ENTER] ~= nil then
        local baseSelEnter = mSel[INTERFACEMODE_ENTER];
        mSel[INTERFACEMODE_ENTER] = function(eNewMode)
            ClearFormationHighlight();
            return baseSelEnter(eNewMode);
        end;
    end
    Log("deploy/rebase/formation handlers re-bound");
end

Log("loaded");
