-- =====================================================
-- 示例12: 综合应用 - 智能温控系统
-- =====================================================
-- 演示: 综合使用定时器、协程、发布订阅、串口通信

print("=== 智能温控系统示例 ===")

-- 系统状态
local SystemState = {
    targetTemp = 25.0,      -- 目标温度
    currentTemp = 0,        -- 当前温度
    heaterOn = false,       -- 加热器状态
    tolerance = 1.0,        -- 容差
    running = true,         -- 运行标志
}

-- 温控逻辑
local function temperatureControl()
    if not SystemState.running then return end

    -- 读取当前温度 (模拟)
    SystemState.currentTemp = 22 + math.random() * 8

    -- PID控制简化版
    local error = SystemState.targetTemp - SystemState.currentTemp

    if error > SystemState.tolerance then
        -- 温度低于目标，开启加热
        if not SystemState.heaterOn then
            SystemState.heaterOn = true
            apiSend("uart", "HEATER_ON\r\n")
            log.info("CONTROL", "加热器开启")
        end
    elseif error < -SystemState.tolerance then
        -- 温度高于目标，关闭加热
        if SystemState.heaterOn then
            SystemState.heaterOn = false
            apiSend("uart", "HEATER_OFF\r\n")
            log.info("CONTROL", "加热器关闭")
        end
    end

    -- 更新图表
    apiAddPoint(SystemState.currentTemp, 1)
    apiAddPoint(SystemState.targetTemp, 2)
    apiAddPoint(SystemState.heaterOn and 100 or 0, 3)

    -- 状态日志
    log.debug("TEMP", string.format("当前: %.1f°C  目标: %.1f°C  加热: %s",
        SystemState.currentTemp,
        SystemState.targetTemp,
        SystemState.heaterOn and "ON" or "OFF"))
end

-- 设置目标温度
local function setTargetTemp(temp)
    SystemState.targetTemp = temp
    log.info("CONTROL", "目标温度设置为: " .. temp .. "°C")
    sys.publish("TARGET_CHANGED", temp)
end

-- 处理串口命令
apiSetCb("uart", function(data)
    -- 解析命令格式: SET_TEMP:25.5
    local temp = data:match("SET_TEMP:([%d%.]+)")
    if temp then
        setTargetTemp(tonumber(temp))
        apiSend("uart", "OK:" .. temp .. "\r\n")
    end

    -- 停止命令
    if data:find("STOP") then
        SystemState.running = false
        log.warn("CONTROL", "系统停止")
    end

    -- 启动命令
    if data:find("START") then
        SystemState.running = true
        log.info("CONTROL", "系统启动")
    end
end)

-- 主控循环
sys.timerLoopStart(temperatureControl, 500)

-- 定期报告
sys.timerLoopStart(function()
    sys.publish("STATUS_REPORT", SystemState.currentTemp, SystemState.heaterOn)
end, 5000)

-- 订阅状态报告
sys.subscribe("STATUS_REPORT", function(temp, heater)
    log.info("REPORT", string.format("温度: %.1f°C  加热器: %s", temp, heater and "ON" or "OFF"))
end)

-- 用户输入: 设置目标温度
sys.taskInit(function()
    sys.wait(3000)  -- 等待系统稳定

    local input = apiInputBox("请输入目标温度 (°C):", "25.0", "温控设置")
    if input and tonumber(input) then
        setTargetTemp(tonumber(input))
    end
end)

print("智能温控系统已启动")
print("命令: SET_TEMP:xx.x  |  START  |  STOP")
