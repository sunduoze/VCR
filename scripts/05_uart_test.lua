-- UART 测试脚本
-- 注意：sys.wait() 必须在 sys.taskInit() 创建的协程中运行

-- 设备名称（需要在 UI 中选择设备）
local deviceName = "COM3"  -- 根据实际情况修改

sys.taskInit(function()
    print("[UART Test] Starting...")
    
    -- 发送测试数据
    local testData = "Hello UART!\r\n"
    apiSend(testData)
    print("[UART Test] Sent: " .. testData:toHex())
    
    -- 注册接收回调
    apiSetCb("uart", function(data)
        print("[UART Test] Received: " .. data:toHex())
    end)
    
    -- 等待响应
    sys.wait(1000)
    
    -- 发送第二帧
    apiSend("Second frame\r\n")
    sys.wait(1000)
    
    -- 取消回调
    apiUnsetCb("uart")
    print("[UART Test] Done")
end)

print("[UART Test] Script loaded")
