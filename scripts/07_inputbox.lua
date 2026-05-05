-- =====================================================
-- 示例7: 用户输入对话框
-- =====================================================
-- 演示: apiInputBox

print("=== 用户输入示例 ===")

sys.taskInit(function()
    print("请求用户输入...")

    -- 弹出输入框 (prompt, default, title)
    local input = apiInputBox("请输入设备名称:", "Device_001", "设备配置")

    if input and input ~= "" then
        print("用户输入:", input)

        -- 使用用户输入
        local cmd = "SET_NAME:" .. input .. "\r\n"
        apiSend("uart", cmd)
    else
        print("用户取消输入")
    end
end)
