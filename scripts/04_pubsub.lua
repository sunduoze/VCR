-- =====================================================
-- 示例4: 发布订阅消息系统
-- =====================================================
-- 演示: sys.subscribe, sys.unsubscribe, sys.publish

print("=== 发布订阅示例 ===")

-- 订阅 "DATA_RECEIVED" 事件
sys.subscribe("DATA_RECEIVED", function(data)
    print("收到数据:", data)
end)

-- 订阅 "STATUS_CHANGED" 事件
sys.subscribe("STATUS_CHANGED", function(status, timestamp)
    print("状态变更:", status, "时间:", timestamp)
end)

-- 订阅带协程的示例
sys.taskInit(function()
    print("等待 ALARM 事件...")
    local received, msg = sys.waitUntil("ALARM", 5000)  -- 最多等5秒
    if received then
        print("收到 ALARM:", msg)
    else
        print("超时未收到 ALARM")
    end
end)

-- 延迟发布事件
sys.timerStart(function()
    print("发布 DATA_RECEIVED 事件")
    sys.publish("DATA_RECEIVED", "Hello from timer!")
end, 1000)

sys.timerStart(function()
    print("发布 STATUS_CHANGED 事件")
    sys.publish("STATUS_CHANGED", "RUNNING", "10:30:00")
end, 1500)

sys.timerStart(function()
    print("发布 ALARM 事件")
    sys.publish("ALARM", "温度过高!")
end, 2000)
