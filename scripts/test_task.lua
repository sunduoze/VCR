-- 软件有自动保存功能
-- 请勿在开启本软件的同时用其他编辑器编辑此处打开了的脚本
-- 以免被覆盖掉
-- 建议在此处 require 你在修改的脚本

-- 注册串口接收函数
apiSetCb("uart", function(data)
    log.info("uart receive", string.toHex(data))
    sys.publish("UART", data)  -- 发布消息
end)

-- 新建任务：等待 UART 消息并回复
sys.taskInit(function()
    while true do
        -- 等待 "UART" 事件，超时 1000ms
        local r, udata = sys.waitUntil("UART", 1000)
        if r then
            log.info("uart wait", "received", string.toHex(udata))
            -- 发送串口回复
            local sendResult = apiSend("uart", "ok!")
            log.info("uart send", sendResult)
        end
    end
end)

-- 新建任务：每 1000ms 计数一次
sys.taskInit(function()
    local count = 0
    while true do
        sys.wait(1000)  -- 等待 1000ms
        count = count + 1
        log.info("task wait", "tick", count)
    end
end)

-- 1000ms 循环定时器
sys.timerLoopStart(function()
    log.info("timer", "test")
end, 1000)
