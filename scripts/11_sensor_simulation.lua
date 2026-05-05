-- =====================================================
-- 示例11: 模拟传感器读取
-- =====================================================
-- 演示: 完整的传感器数据处理流程

print("=== 传感器模拟示例 ===")

local SensorType = {
    TEMPERATURE = 0x01,
    HUMIDITY = 0x02,
    PRESSURE = 0x03,
}

local sensorData = {
    temperature = 0,
    humidity = 0,
    pressure = 0,
}

-- 模拟传感器读取 (实际应用中通过串口读取)
local function readSensor(type)
    if type == SensorType.TEMPERATURE then
        return 20 + math.random() * 10  -- 20-30°C
    elseif type == SensorType.HUMIDITY then
        return 40 + math.random() * 20  -- 40-60%
    elseif type == SensorType.PRESSURE then
        return 1000 + math.random() * 50  -- 1000-1050 hPa
    end
    return 0
end

-- 数据采集任务
sys.taskInit(function()
    while true do
        -- 读取传感器
        sensorData.temperature = readSensor(SensorType.TEMPERATURE)
        sensorData.humidity = readSensor(SensorType.HUMIDITY)
        sensorData.pressure = readSensor(SensorType.PRESSURE)

        -- 打印数据
        print(string.format("温度: %.1f°C  湿度: %.1f%%  气压: %.1f hPa",
            sensorData.temperature,
            sensorData.humidity,
            sensorData.pressure))

        -- 更新图表
        apiAddPoint(sensorData.temperature, 1)
        apiAddPoint(sensorData.humidity, 2)

        -- 检查告警
        if sensorData.temperature > 28 then
            sys.publish("ALARM", "HIGH_TEMP", sensorData.temperature)
        end

        sys.wait(2000)  -- 每2秒采集一次
    end
end)

-- 订阅告警
sys.subscribe("ALARM", function(alarmType, value)
    log.warn("ALARM", string.format("告警! %s = %.1f", alarmType, value))
end)

print("传感器模拟已启动")
