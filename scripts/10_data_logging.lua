-- =====================================================
-- 示例10: 数据记录与导出
-- =====================================================
-- 演示: 定时采集、数据缓存、格式化输出

print("=== 数据记录示例 ===")

local dataLog = {}
local MAX_LOG = 100

-- 记录数据
local function logData(timestamp, value)
    table.insert(dataLog, {time = timestamp, val = value})
    if #dataLog > MAX_LOG then
        table.remove(dataLog, 1)
    end
end

-- 导出为CSV格式
local function exportCSV()
    local lines = {"Timestamp,Value"}
    for _, entry in ipairs(dataLog) do
        table.insert(lines, entry.time .. "," .. entry.val)
    end
    return table.concat(lines, "\n")
end

-- 采集计数器（os模块不可用，用计数器代替时间戳）
local sampleCount = 0

-- 模拟数据采集 (实际应用中从串口读取)
sys.timerLoopStart(function()
    sampleCount = sampleCount + 1
    local timestamp = "S" .. sampleCount  -- 序号代替时间戳
    local value = math.random() * 100

    logData(timestamp, value)
    apiAddPoint(value, 1)  -- 同时绘制到图表

    print("采集:", timestamp, string.format("%.2f", value))
end, 1000)

-- 每10秒导出一次
sys.timerLoopStart(function()
    if #dataLog > 0 then
        print("=== 数据导出 ===")
        print(exportCSV())
        print("===============")
    end
end, 10000)

print("数据记录已启动")
