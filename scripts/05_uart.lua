-- =====================================================
-- 示例5: 串口通信
-- =====================================================
-- 演示: apiSend, apiSetCb
-- 注意: 需要先连接设备并选择设备ID

print('=== 串口通信示例 ===')
print('[提示] 请先选择设备后点击运行')

-- 注册串口接收回调
apiSetCb('uart', function(data)
    print('[接收] 数据:', data)
    print('[十六进制] :', string.toHex(data))
end)

-- 发送字符串
local function sendString(str)
    print('发送 : ' .. str)
    local result = apiSend('uart', str)
    if result then
        print('发送成功')
    else
        print('发送失败 result=false')
    end
end

-- 必须在协程中使用 sys.wait
sys.taskInit(function()
    -- 发送 AT 命令测试
    print('---')
    sendString('AT\r\n')
    sys.wait(500)
    sendString('ATI\r\n')
    sys.wait(500)

    print('串口示例已启动')
end)
