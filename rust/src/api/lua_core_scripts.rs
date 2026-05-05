//! LLCOM 核心脚本（内嵌，初始化时自动加载）
//! 包含 log.lua、sys.lua、head.lua 的适配版本

/// log.lua — 日志模块
pub const LOG_LUA: &str = r#"
LOG_SILENT = LOGLEVEL_TRACE;
LOGLEVEL_TRACE = 0x01;
LOGLEVEL_DEBUG = 0x02;
LOGLEVEL_INFO = 0x03;
LOGLEVEL_WARN = 0x04;
LOGLEVEL_ERROR = 0x05;
LOGLEVEL_FATAL = 0x06;

local LEVEL_TAG = {'T', 'D', 'I', 'W', 'E', 'F'}
local PREFIX_FMT = "[%s]-[%s]"

local log = {}

local function _log(level, tag, ...)
    local OPENLEVEL = LOG_LEVEL and LOG_LEVEL or LOGLEVEL_INFO
    if OPENLEVEL == LOG_SILENT or OPENLEVEL > level then return end
    local prefix = string.format(PREFIX_FMT, LEVEL_TAG[level], type(tag)=="string" and tag or "")
    print(prefix, ...)
end

function log.trace(tag, ...) _log(LOGLEVEL_TRACE, tag, ...) end
function log.debug(tag, ...) _log(LOGLEVEL_DEBUG, tag, ...) end
function log.info(tag, ...)  _log(LOGLEVEL_INFO, tag, ...) end
function log.warn(tag, ...)  _log(LOGLEVEL_WARN, tag, ...) end
function log.error(tag, ...) _log(LOGLEVEL_ERROR, tag, ...) end
function log.fatal(tag, ...) _log(LOGLEVEL_FATAL, tag, ...) end

return log
"#;

/// sys.lua — 协程调度框架（适配版）
pub const SYS_LUA: &str = r#"
local sys = {}

local TASK_TIMER_ID_MAX = 0x1FFFFFFF
local MSG_TIMER_ID_MAX = 0x7FFFFFFF

local taskTimerId = 0
local msgId = TASK_TIMER_ID_MAX
local timerPool = {}
local taskTimerPool = {}
local para = {}
local loop = {}

function sys.wait(ms)
    assert(ms > 0, "The wait time cannot be negative!")
    if taskTimerId >= TASK_TIMER_ID_MAX then taskTimerId = 0 end
    taskTimerId = taskTimerId + 1
    local timerid = taskTimerId
    taskTimerPool[coroutine.running()] = timerid
    timerPool[timerid] = coroutine.running()
    if 1 ~= apiStartTimer(timerid, ms) then log.debug("apiStartTimer error") return end
    local message = {coroutine.yield()}
    if #message ~= 0 then
        apiStopTimer(timerid)
        taskTimerPool[coroutine.running()] = nil
        timerPool[timerid] = nil
        return table.unpack(message)
    end
end

function sys.waitUntil(id, ms)
    sys.subscribe(id, coroutine.running())
    local message = ms and {sys.wait(ms)} or {coroutine.yield()}
    sys.unsubscribe(id, coroutine.running())
    return message[1] ~= nil, table.unpack(message, 2, #message)
end

function sys.waitUntilExt(id, ms)
    sys.subscribe(id, coroutine.running())
    local message = ms and {sys.wait(ms)} or {coroutine.yield()}
    sys.unsubscribe(id, coroutine.running())
    if message[1] ~= nil then return table.unpack(message) end
    return false
end

function sys.taskInit(fun, ...)
    local arg = { ... }
    local co = coroutine.create(fun)
    assert(coroutine.resume(co, table.unpack(arg)))
    return co
end

local function cmpTable(t1, t2)
    if not t2 then return #t1 == 0 end
    if #t1 == #t2 then
        for i = 1, #t1 do
            if table.unpack(t1, i, i) ~= table.unpack(t2, i, i) then
                return false
            end
        end
        return true
    end
    return false
end

function sys.timerStop(val, ...)
    local arg = { ... }
    if type(val) == 'number' then
        timerPool[val], para[val], loop[val] = nil
        apiStopTimer(val)
    else
        for k, v in pairs(timerPool) do
            if type(v) == 'table' and v.cb == val or v == val then
                if cmpTable(arg, para[k]) then
                    apiStopTimer(k)
                    timerPool[k], para[k], loop[val] = nil
                    break
                end
            end
        end
    end
end

function sys.timerStopAll(fnc)
    for k, v in pairs(timerPool) do
        if type(v) == "table" and v.cb == fnc or v == fnc then
            apiStopTimer(k)
            timerPool[k], para[k], loop[k] = nil
        end
    end
end

function sys.timerStart(fnc, ms, ...)
    local arg = { ... }
    assert(fnc ~= nil, "sys.timerStart(first param) is nil !")
    assert(ms > 0, "sys.timerStart(Second parameter) is <= zero !")
    if arg.n == 0 then
        sys.timerStop(fnc)
    else
        sys.timerStop(fnc, table.unpack(arg))
    end
    while true do
        if msgId >= MSG_TIMER_ID_MAX then msgId = TASK_TIMER_ID_MAX end
        msgId = msgId + 1
        if timerPool[msgId] == nil then
            timerPool[msgId] = fnc
            break
        end
    end
    if apiStartTimer(msgId, ms) ~= 1 then log.debug("apiStartTimer error") return end
    if arg.n ~= 0 then
        para[msgId] = arg
    end
    return msgId
end

function sys.timerLoopStart(fnc, ms, ...)
    local arg = { ... }
    local tid = sys.timerStart(fnc, ms, table.unpack(arg))
    if tid then loop[tid] = ms end
    return tid
end

function sys.timerIsActive(val, ...)
    local arg = { ... }
    if type(val) == "number" then
        return timerPool[val]
    else
        for k, v in pairs(timerPool) do
            if v == val then
                if cmpTable(arg, para[k]) then return true end
            end
        end
    end
end

local subscribers = {}
local messageQueue = {}

function sys.subscribe(id, callback)
    if type(id) ~= "string" or (type(callback) ~= "function" and type(callback) ~= "thread") then
        log.warn("warning: sys.subscribe invalid parameter", id, callback)
        return
    end
    if not subscribers[id] then subscribers[id] = {} end
    subscribers[id][callback] = true
end

function sys.unsubscribe(id, callback)
    if type(id) ~= "string" or (type(callback) ~= "function" and type(callback) ~= "thread") then
        log.warn("warning: sys.unsubscribe invalid parameter", id, callback)
        return
    end
    if subscribers[id] then subscribers[id][callback] = nil end
end

function sys.publish(...)
    local arg = { ... }
    table.insert(messageQueue, arg)
    dispatch()
end

function dispatch()
    while true do
        if #messageQueue == 0 then break end
        local message = table.remove(messageQueue, 1)
        if subscribers[message[1]] then
            local cbs = {}
            for callback, _ in pairs(subscribers[message[1]]) do
                table.insert(cbs, callback)
            end
            for _, callback in ipairs(cbs) do
                if type(callback) == "function" then
                    callback(table.unpack(message, 2, #message))
                elseif type(callback) == "thread" then
                    local r, i = coroutine.resume(callback, table.unpack(message))
                    if not r then
                        assert(r, tostring(i))
                    end
                end
            end
        end
    end
end

function sys.tigger(param)
    if param < TASK_TIMER_ID_MAX then
        local taskId = timerPool[param]
        timerPool[param] = nil
        if taskTimerPool[taskId] == param then
            taskTimerPool[taskId] = nil
            local r, i = coroutine.resume(taskId)
            i = i and i..",hex:"..i:toHex() or nil
            assert(r, i)
        end
    else
        local cb = timerPool[param]
        if not loop[param] then timerPool[param] = nil end
        if not cb then timerPool[param] = nil return end
        if para[param] ~= nil then
            cb(table.unpack(para[param]))
            if not loop[param] then para[param] = nil end
        else
            cb()
        end
        if loop[param] then apiStartTimer(param, loop[param]) end
    end
end

return sys
"#;

/// head.lua — 核心初始化脚本（适配版）
/// 与 LLCOM 原版差异：
/// - 移除了中文路径 workarounds（apiUtf8ToHex 不再需要）
/// - 移除了 runType/runMaxSeconds 超时机制（简化）
/// - apiSetCb/apiUnsetCb 已由 Rust 侧实现，此处定义 Lua 侧的 channelCb 表
/// - tiggerCB 是定时器和通道回调的统一入口
pub const HEAD_LUA: &str = r#"
-- 加强随机数（使用固定种子，因 os 模块不可用）
math.randomseed(123456789)

-- 设置 package.path（用户脚本目录）
local rootPath = apiGetPath()
package.path = package.path
    .. ";" .. rootPath .. "?.lua"
    .. ";" .. rootPath .. "core_script/?.lua"
    .. ";" .. rootPath .. "user_script/?.lua"

-- 重写 print 函数，走 apiPrintLog
function print(...)
    local logAll = {}
    for i = 1, select('#', ...) do
        local arg = select(i, ...)
        table.insert(logAll, tostring(arg))
    end
    apiPrintLog(table.concat(logAll, "\t"))
end

-- 加载 log 模块
log = require("log")

-- 加载 sys 模块
sys = require("sys")

-- Lua 侧 channel 回调表（与 Rust 侧 CALLBACKS 互补）
-- Rust 侧 trigger_callback 直接调用 Lua 全局函数，
-- 这里提供 tiggerCB 作为 Rust → Lua 的桥接
local channelCb = {}

-- 覆盖 Rust 侧的 apiSetCb，改为 Lua 侧管理
-- （Rust 侧的 apiSetCb 仍然注册到 CALLBACKS，但 tiggerCB 走 Lua 侧 channelCb）
_rawApiSetCb = apiSetCb
_rawApiUnsetCb = apiUnsetCb

function apiSetCb(channel, cb)
    if not channelCb[channel] then
        channelCb[channel] = {}
    end
    table.insert(channelCb[channel], cb)
end

function apiUnsetCb(channel, cb)
    if not channelCb[channel] then return true end
    for i = 1, #channelCb[channel] do
        if channelCb[channel][i] == cb then
            table.remove(channelCb[channel], i)
            if #channelCb[channel] == 0 then
                channelCb[channel] = nil
            end
            return true
        end
    end
end

-- 协程/定时器外部触发入口
-- id >= 0: 定时器消息 → sys.tigger(id)
-- id < 0: 通道消息 → channelCb[type] 回调
tiggerCB = function(id, msgType, data)
    local result, info = pcall(function()
        if id >= 0 then
            sys.tigger(id)
        else
            if channelCb[msgType] then
                for i = 1, #channelCb[msgType] do
                    channelCb[msgType][i](data)
                end
            end
        end
    end)
    if not result then
        log.error("task", "run failed\r\n" .. tostring(info))
    end
end

-- 兼容老的串口接口
apiSendUartData = function(data)
    return apiSend("uart", data)
end

-- 默认注册 uart 回调
apiSetCb("uart", function(data)
    if uartReceive then uartReceive(data) end
end)
"#;
