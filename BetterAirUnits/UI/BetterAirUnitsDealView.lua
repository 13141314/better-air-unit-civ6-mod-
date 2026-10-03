-- BetterAirUnitsDealView.lua
-- 交易页（DiplomacyDealView 上下文）的“机位租借”扩展 v2：
--   行放在“我的库存”列的“协议”分组里（与“开放边界”同一列表、同款样式），
--   不再挤在顶部按钮区。同意改为直接点击行，不再依赖“接受交易”按钮：
--     1) 机位租借开关：向对方请求租用其机位（点击开启/取消）
--     2) 对方有请求时：同意 / 拒绝 两行（点击同意即刻开放）
--     3) 我方已开放：点击收回
--     4) 对方已开放给我方：只读提示
--   状态读写走 PlayerProperties（BetterAir_RentReq / BetterAir_RentGrant），
--   写入一律通过 EXECUTE_SCRIPT 中继给 gameplay（BetterAirRentOp）。

-- 先加载原版链（ReplaceUIScript 入口）。引擎把 include(原名) 解析到原始文件。
print("[BetterAirRent] entry running");
local okChain = pcall(include, "DiplomacyDealView");
if not okChain then
    pcall(include, "DiplomacyDealView_Expansion2");
end

local DEBUG = false;   -- 发布版：需要排障时改回 true
-- ★ 机位租借 UI 总开关：改成 false 并保存，本文件就只把原版交易页链接起来，
--   不再往“协议”列表注入任何租借行（想安静玩游戏时关掉它，不影响其它功能）。
local BAR_RENT_UI_ENABLED = true;

local function Log(msg)
    if DEBUG then print("[BetterAirRent] " .. msg); end
end

if not BAR_RENT_UI_ENABLED then
    Log("租借 UI 已由总开关关闭（BAR_RENT_UI_ENABLED=false），本文件只保留原版交易页");
    return;
end

local g_BAR_OK = false;
if type(OnShow) ~= "function" then
    Log("ERROR: deal chain not loaded (no OnShow), rent UI disabled");
else
    g_BAR_OK = true;
end

-- ===========================================================================
-- 属性访问加固（2026-10-03）—— 崩溃根因修复（详见 Scripts/BetterAirUnits.lua 顶部）
-- 引擎的 GetProperty 是"全局唯一"的 Lua 绑定（lGetProperty RVA 0x1d500），
-- 它按 [obj.vtbl+0x50] 取属性容器；对手是 table / 别的 context 的 stub /
-- 未存活槽位时会拿垃圾指针直接崩（读地址 0x528，RVA 0x1533e）。
-- ===========================================================================
local TRACE_PROPS = false;   -- 发布版：需要排障时改回 true
local g_PropTraceBudget = 20;   -- 每"轮"最多打印多少条诊断（避免全槽位扫描刷屏）
local function PropTrace(msg)
    if not TRACE_PROPS or g_PropTraceBudget <= 0 then return end
    g_PropTraceBudget = g_PropTraceBudget - 1;
    print(msg .. (g_PropTraceBudget == 0 and "   [后续 TRACE 已折叠]" or ""));
end

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
        PropTrace(string.format("[BetterAirRent] GetProp BLOCKED obj=%s key=%s", PropTargetDesc(o), tostring(key)));
        return nil;
    end
    local ok, v = pcall(function() return t:GetProperty(key) end);
    if not ok then return nil; end
    return v;
end
-- 玩家守卫：同样要走 PropTarget 解包 —— 热座/UI 上下文里 Players[i] 是 table，
-- 直接判 type(p)=="userdata" 会把两个人类玩家全判成"非存活"（实测热座局全灭）。
local function PlayerAlive(p)
    local t = PropTarget(p);
    if t == nil then return false end
    local ok, alive = pcall(function() return t:IsAlive() end);
    return ok and alive == true;
end

local RENT_REQ_KEY = "BetterAir_RentReq";
local RENT_GRANT_KEY = "BetterAir_RentGrant";
local LOCAL_PLAYER_TYPE = 1;   -- 原版 DiplomacyDealView.lua 的 local LOCAL_PLAYER = 1

local function BitGet(mask, i)
    if mask == nil or i == nil or i < 0 then return false end
    mask = math.floor(tonumber(mask) or 0);
    return math.floor(mask / 2^i) % 2 == 1;
end
local function BitSet(mask, i, on)
    mask = math.floor(tonumber(mask) or 0);
    if BitGet(mask, i) then
        if on then return mask else return mask - 2^i end
    else
        if on then return mask + 2^i else return mask end
    end
end

-- UI 侧镜像缓存（读不到 PlayerProperties 时的兜底；gameplay 是唯一真相）
local g_BAR_Cache = {};
local function BAR_GetMask(pid, key)
    local p = Players[pid];
    -- 修复：UI 上下文里 Players[pid] 未必是可读属性的对象；且 UI 侧 Player:GetProperty
    -- 从无可靠先例（见 UI/BetterAirUnitsWorldInput.lua 的注释）。先判存活再读。
    if p ~= nil and not PlayerAlive(p) then
        PropTrace(string.format("[BetterAirRent] TRACE BAR_GetMask skip non-alive p=%s key=%s", tostring(pid), tostring(key)));
        p = nil;
    end
    if p ~= nil then
        local ok, v = pcall(function() return GetProp(p, key) end);
        if ok and v ~= nil then
            local n = math.floor(tonumber(v) or 0);
            if g_BAR_Cache[pid] == nil then g_BAR_Cache[pid] = {}; end
            g_BAR_Cache[pid][key] = n;
            return n;
        end
    end
    local c = g_BAR_Cache[pid];
    if c ~= nil and c[key] ~= nil then return c[key] end
    return 0;
end
local function BAR_SetCache(pid, key, val)
    if g_BAR_Cache[pid] == nil then g_BAR_Cache[pid] = {}; end
    g_BAR_Cache[pid][key] = math.floor(val or 0);
end

local function BAR_Relay(op, other, on)
    local meId = Game.GetLocalPlayer();
    if meId < 0 or other == nil or other < 0 or other == meId then return; end
    local ok = pcall(function()
        UI.RequestPlayerOperation(meId, PlayerOperations.EXECUTE_SCRIPT, {
            OnStart = "BetterAirRentOp",
            Op = op,
            Other = other,
            On = on and 1 or 0,
        });
    end);
    -- 本地镜像按 gameplay 同规则预测一份
    if op == "req" then
        BAR_SetCache(meId, RENT_REQ_KEY, BitSet(BAR_GetMask(meId, RENT_REQ_KEY), other, on));
    elseif op == "grant" then
        BAR_SetCache(meId, RENT_GRANT_KEY, BitSet(BAR_GetMask(meId, RENT_GRANT_KEY), other, on));
        if on then
            BAR_SetCache(other, RENT_REQ_KEY, BitSet(BAR_GetMask(other, RENT_REQ_KEY), meId, false));
        end
    elseif op == "revoke" then
        BAR_SetCache(meId, RENT_GRANT_KEY, BitSet(BAR_GetMask(meId, RENT_GRANT_KEY), other, false));
    elseif op == "rejectreq" then
        BAR_SetCache(other, RENT_REQ_KEY, BitSet(BAR_GetMask(other, RENT_REQ_KEY), meId, false));
    end
    Log(string.format("rent relay op=%s other=%d on=%s ok=%s", tostring(op), other, tostring(on), tostring(ok)));
end

local function BAR_T(key, fallback)
    local s = nil;
    pcall(function() s = Locale.Lookup(key) end);
    if s == nil or s == key then return fallback; end
    return s;
end

-- 私有实例管理器：复用原版 IconAndText 模板（“开放边界”同款行）
local g_BAR_IM = nil;
if g_BAR_OK then
    local okIM = pcall(function()
        g_BAR_IM = InstanceManager:new("IconAndText", "SelectButton", Controls.IconAndTextContainer);
    end);
    if not okIM then
        Log("ERROR: rent IM creation failed");
        g_BAR_IM = nil;
    end
end

-- 取“我的库存”列的“协议”分组（TopDownList 实例：List/Title/ListStack/GetTopControl）；
-- 拿不到时（被别的模组改结构等），在库存栈里自建一个带标题的分组兜底
local g_BAR_FallbackIM = nil;
local g_BAR_FallbackGroup = nil;
local function BAR_GetAgreementsGroup()
    local group = nil;
    pcall(function()
        if g_AvailableGroups ~= nil and AvailableDealItemGroupTypes ~= nil then
            local tg = g_AvailableGroups[AvailableDealItemGroupTypes.AGREEMENTS];
            if tg ~= nil then group = tg[LOCAL_PLAYER_TYPE] end
        end
    end);
    if group ~= nil and group.ListStack ~= nil then return group end
    if g_BAR_FallbackIM == nil then
        local ok = pcall(function()
            g_BAR_FallbackIM = InstanceManager:new("TopDownList", "List", Controls.MyInventoryStack);
        end);
        if not ok then return nil end
    end
    if g_BAR_FallbackGroup == nil then
        local ok = pcall(function()
            g_BAR_FallbackGroup = g_BAR_FallbackIM:GetInstance(Controls.MyInventoryStack);
            g_BAR_FallbackGroup.TitleText:SetText("机位租借");
        end);
        if not ok or g_BAR_FallbackGroup == nil then return nil end
    end
    return g_BAR_FallbackGroup;
end

local g_BAR_Other = -1;   -- 当前会话对方 id（缓存，供行回调使用）

local function BAR_AddRow(text, tip, onClick)
    if g_BAR_IM == nil then return; end
    local group = BAR_GetAgreementsGroup();
    if group == nil then return; end
    local ok, err = pcall(function()
        local inst = g_BAR_IM:GetInstance(group.ListStack);
        if inst == nil then return end;
        pcall(function() inst.SelectButton:SetSizeXY(232, 56); end);
        -- 不再引用图标名：本机游戏数据里查不到 ICON_DOMAIN_AIR / ICON_GRANT_OPEN_BORDERS，
        -- 引用不存在的图标会每帧刷 [DataError] Control 'Icon' missing texture。直接隐藏图标位。
        pcall(function() inst.Icon:SetHide(true); end);
        pcall(function() inst.IconAnchor:SetHide(true); end);
        pcall(function() inst.AmountText:SetHide(true); end);
        pcall(function() inst.IconText:SetText(text); inst.IconText:SetWrapWidth(215); end);
        pcall(function() inst.ValueText:SetHide(true); end);
        pcall(function() inst.RemoveButton:SetHide(true); end);
        pcall(function() inst.StopAskingButton:SetHide(true); end);
        pcall(function() inst.UnacceptableIcon:SetHide(true); end);
        inst.SelectButton:SetToolTipString(tip);
        if onClick ~= nil then
            inst.SelectButton:RegisterCallback(Mouse.eLClick, onClick);
        end
    end);
    if not ok then Log("BAR_AddRow failed: " .. tostring(err)); end
end

function BAR_Refresh()
    if not g_BAR_OK or g_BAR_IM == nil then return; end
    pcall(function()
        g_BAR_IM:ResetInstances();
        local group = BAR_GetAgreementsGroup();
        if group == nil then Log("refresh: no agreements group"); return; end

        local other = -1;
        pcall(function() if g_OtherPlayer ~= nil then other = g_OtherPlayer:GetID() end end);
        g_BAR_Other = other;
        local meId = Game.GetLocalPlayer();
        if meId < 0 or other < 0 or other == meId then
            Log(string.format("refresh: bad pair me=%d other=%d", meId, other)); return;
        end
        local otherP = Players[other];
        if otherP == nil or not otherP:IsHuman() then
            Log("refresh: other not human, rent needs human-vs-human"); return;
        end

        local reqMaskMe    = BAR_GetMask(meId, RENT_REQ_KEY);
        local reqMaskOther = BAR_GetMask(other, RENT_REQ_KEY);
        local grantMe      = BAR_GetMask(meId, RENT_GRANT_KEY);
        local grantOther   = BAR_GetMask(other, RENT_GRANT_KEY);
        local myReq        = BitGet(reqMaskMe, other);
        local otherReqMe   = BitGet(reqMaskOther, meId);
        local iGrantOther  = BitGet(grantMe, other);
        local otherGrants  = BitGet(grantOther, meId);

        -- 行1：我的租借请求开关
        if myReq then
            BAR_AddRow(BAR_T("LOC_BETTER_AIR_RENT_TOGGLE_ON", "机位租借：请求中（点击取消）"),
                BAR_T("LOC_BETTER_AIR_RENT_TT",
                  "点击后向对方发出机位租借请求（仅人类玩家之间可租借）。对方在其交易界面的“协议”列表点击同意后，你的飞机即可部署进驻对方的航空港、市中心或跑道（含相邻格）。战争期间租借自动暂停，恢复和平自动生效；可随时点击取消请求。"),
                function() BAR_Relay("req", g_BAR_Other, false); pcall(BAR_Refresh); end);
        else
            BAR_AddRow(BAR_T("LOC_BETTER_AIR_RENT_TOGGLE_OFF", "机位租借：点击请求进驻"),
                BAR_T("LOC_BETTER_AIR_RENT_TT",
                  "点击后向对方发出机位租借请求（仅人类玩家之间可租借）。对方在其交易界面的“协议”列表点击同意后，你的飞机即可部署进驻对方的航空港、市中心或跑道（含相邻格）。战争期间租借自动暂停，恢复和平自动生效；可随时点击取消请求。"),
                function() BAR_Relay("req", g_BAR_Other, true); pcall(BAR_Refresh); end);
        end

        -- 行2/3：对方的请求 → 直接同意 / 拒绝（无需成交交易）
        if otherReqMe and not iGrantOther then
            BAR_AddRow(BAR_T("LOC_BETTER_AIR_RENT_INCOMING", "同意对方租用我方机位（点击）"),
                BAR_T("LOC_BETTER_AIR_RENT_INCOMING_TT",
                  "点击即刻开放：对方的飞机即可把基地进驻你的航空港/市中心/跑道（含相邻格）。战争期间自动暂停，恢复和平自动生效；可随时点击收回。"),
                function() BAR_Relay("grant", g_BAR_Other, true); pcall(BAR_Refresh); end);
            BAR_AddRow(BAR_T("LOC_BETTER_AIR_RENT_REJECT", "拒绝机位租借请求（点击）"),
                BAR_T("LOC_BETTER_AIR_RENT_REJECT_TT", "拒绝并撤回对方的请求；不影响其之后再次发起请求。"),
                function() BAR_Relay("rejectreq", g_BAR_Other, nil); pcall(BAR_Refresh); end);
        end

        -- 行4：我方已开放给对方
        if iGrantOther then
            BAR_AddRow(BAR_T("LOC_BETTER_AIR_RENT_MYGRANT", "已租机位给对方（点击收回）"),
                BAR_T("LOC_BETTER_AIR_RENT_MYGRANT_TT", "收回后，对方停在我方地块上的飞机基地锚点会在下个回合开始时移回其所在位置。"),
                function() BAR_Relay("grant", g_BAR_Other, false); pcall(BAR_Refresh); end);
        end

        -- 行5：对方已开放给我方（只读）
        if otherGrants then
            BAR_AddRow(BAR_T("LOC_BETTER_AIR_RENT_THEIRGRANT", "对方已开放机位 ✓"),
                BAR_T("LOC_BETTER_AIR_RENT_THEIRGRANT_TT", "选中飞机 → 部署，右键点击对方的航空港/市中心/跑道即可进驻并把基地迁过去。"),
                nil);
        end

        -- 若“协议”分组因空而被原版隐藏，重新显示并让布局重算
        pcall(function()
            local tc = group.GetTopControl();
            tc:SetHide(false);
        end);
        pcall(function() group.Title:SetHide(false); end);
        pcall(function() group.ListStack:CalculateSize(); group.List:CalculateSize(); end);
        pcall(function() Controls.MyInventoryStack:CalculateSize(); Controls.MyInventoryScroll:CalculateSize(); end);
    end);
end

-- ===========================================================================
-- 挂钩：原版只在 OnShow 时构建一次库存列表，所以刷新挂在 OnShow 之后 + 事件兜底
-- ===========================================================================
if g_BAR_OK then
    if type(UpdateProposedWorkingDeal) == "function" then
        local BASE_UpdateProposedWorkingDeal = UpdateProposedWorkingDeal;
        function UpdateProposedWorkingDeal()
            if BASE_UpdateProposedWorkingDeal then pcall(BASE_UpdateProposedWorkingDeal); end
            pcall(BAR_Refresh);
        end
    end

    local BASE_OnShow = OnShow;
    function OnShow()
        if BASE_OnShow then pcall(BASE_OnShow); end
        pcall(BAR_Refresh);
    end
    pcall(function() ContextPtr:SetShowHandler(OnShow); end);

    -- 成交/来盘事件只做刷新（状态变化后重排行文本）
    local function BAR_SafeAdd(event, handler, name)
        local ok = pcall(event.Add, handler);
        if not ok then pcall(event.Add, event, handler); end
        Log("listener " .. tostring(name) .. " ok=" .. tostring(ok));
    end
    BAR_SafeAdd(Events.DiplomacyDealEnacted, function() pcall(BAR_Refresh); end, "DiplomacyDealEnacted");
    BAR_SafeAdd(Events.DiplomacyIncomingDeal, function() pcall(BAR_Refresh); end, "DiplomacyIncomingDeal");

    Log("rent hooks installed (v2 inventory placement)");
end
