-- =====================================================
-- 示例9: AT指令自动测试
-- =====================================================
-- 演示: AT指令发送、响应等待、超时处理

print("=== AT指令测试示例 ===")

local AT_TIMEOUT = 3000  -- 3秒超时

-- 发送AT指令并等待响应
local function sendATAndWait(cmd, expectedResponse, timeout)
    timeout = timeout or AT_TIMEOUT

    -- 清除之前的响应
    local response = nil

    -- 注册一次性响应回调
    local callback
    callback = function(data)
        if data:find(expectedResponse, 1, true) then
            response = data
            apiUnsetCb("uart", callback)
        end
    end
    apiSetCb("uart", callback)

    -- 发送指令
    apiSend("uart", cmd .. "\r\n")
    print("发送:", cmd)

    -- 等待响应
    local waitTime = 0
    while waitTime < timeout do
        sys.wait(100)
        waitTime = waitTime + 100
        if response then
            print("收到响应:", response)
            return true, response
        end
    end

    -- 超时
    apiUnsetCb("uart", callback)
    print("超时!")
    return false, nil
end

-- AT测试任务
sys.taskInit(function()
    print("开始AT指令测试...")

    -- 测试 AT
    local ok, resp = sendATAndWait("AT", "OK")
    print("AT测试:", ok and "通过" or "失败")

    sys.wait(1000)

    -- 测试 AT+GMR (查询版本)
    ok, resp = sendATAndWait("AT+GMR", "OK")
    if ok then
        print("版本信息:", resp)
    end

    sys.wait(1000)

    -- 测试 AT+CWMODE? (查询WiFi模式)
    ok, resp = sendATAndWait("AT+CWMODE?", "OK")
    if ok then
        print("WiFi模式:", resp)
    end

    print("AT测试完成")
end)
