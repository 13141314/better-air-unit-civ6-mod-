-- BetterAirUnitsUI.lua
-- 在“改变基地”（REBASE）操作完全结束后，通知 gameplay 脚本：
--   按移动力补回剩余移动力，使飞机还能继续空袭。
-- gameplay 脚本自己有幂等保护，重复通知不会重复生效。

local DEBUG = false;   -- 发布版：需要排障时改回 true

local function Log(msg)
    if DEBUG then
        print("[BetterAirUnitsUI] " .. msg);
    end
end

local g_LastRelay = {};  -- key: playerId:unitId:x:y:command -> turn

local function RelayOperationComplete(playerId, unitId, x, y, commandName)
    -- AI 回合由 gameplay 脚本自己的事件处理；这里只补本地玩家的时序兜底
    if playerId ~= Game.GetLocalPlayer() then
        return;
    end

    local unit = UnitManager.GetUnit(playerId, unitId);
    if unit == nil then
        return;
    end
    local unitInfo = GameInfo.Units[unit:GetType()];
    if unitInfo == nil or unitInfo.Domain ~= "DOMAIN_AIR" then
        return;
    end

    local unitX = x or unit:GetX();
    local unitY = y or unit:GetY();
    local turn = Game.GetCurrentGameTurn();
    local key = playerId .. ":" .. unitId .. ":" .. unitX .. ":" .. unitY .. ":" .. commandName;
    if g_LastRelay[key] == turn then
        return;  -- 同一个移动只通知一次
    end
    g_LastRelay[key] = turn;

    local params = {
        OnStart = commandName,
        UnitID = unit:GetID(),
        X = unitX,
        Y = unitY,
    };
    UI.RequestPlayerOperation(playerId, PlayerOperations.EXECUTE_SCRIPT, params);
    Log(string.format("relay p=%d u=%d at (%d,%d) cmd=%s", playerId, unitId, unitX, unitY, commandName));
end

local function RelayRebaseComplete(playerId, unitId, x, y)
    RelayOperationComplete(playerId, unitId, x, y, "ScenarioCommand_BetterAirRebaseComplete");
end

local function RelayDeployComplete(playerId, unitId, x, y)
    RelayOperationComplete(playerId, unitId, x, y, "ScenarioCommand_BetterAirDeployComplete");
end

function OnUnitOperationSegmentComplete(playerId, unitId, hCommand, iData1)
    if hCommand == UnitOperationTypes.REBASE then
        RelayRebaseComplete(playerId, unitId);
    elseif hCommand == UnitOperationTypes.DEPLOY then
        RelayDeployComplete(playerId, unitId);
    end
end
Events.UnitOperationSegmentComplete.Add(OnUnitOperationSegmentComplete);

function OnUnitOperationsCleared(playerId, unitId, hCommand, iData1)
    if hCommand == UnitOperationTypes.REBASE then
        RelayRebaseComplete(playerId, unitId);
    elseif hCommand == UnitOperationTypes.DEPLOY then
        RelayDeployComplete(playerId, unitId);
    end
end
Events.UnitOperationsCleared.Add(OnUnitOperationsCleared);

function OnUnitMoveCompleteRelay(playerId, unitId, x, y)
    RelayDeployComplete(playerId, unitId, x, y);
end
Events.UnitMoveComplete.Add(OnUnitMoveCompleteRelay);

-- 移动力变化后，检查引擎是否允许这架飞机发起空袭（调试用）
function OnUnitMovementPointsChanged(playerId, unitId)
    if playerId ~= Game.GetLocalPlayer() then
        return;
    end
    local unit = UnitManager.GetUnit(playerId, unitId);
    if unit == nil then
        return;
    end
    local unitInfo = GameInfo.Units[unit:GetType()];
    if unitInfo == nil or unitInfo.Domain ~= "DOMAIN_AIR" then
        return;
    end

    local params = {};
    params[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.ATTACK;
    local canStart, results = UnitManager.CanStartOperation(unit, UnitOperationTypes.AIR_ATTACK, nil, params);
    Log(string.format("moves changed: u=%d moves=%d AIR_ATTACK canStart=%s",
        unitId, unit:GetMovesRemaining(), tostring(canStart)));
    if results ~= nil and results[UnitOperationResults.FAILURE_REASONS] ~= nil then
        for _, reason in ipairs(results[UnitOperationResults.FAILURE_REASONS]) do
            Log("  failure reason: " .. tostring(reason));
        end
    end
end
Events.UnitMovementPointsChanged.Add(OnUnitMovementPointsChanged);

Log("loaded");
