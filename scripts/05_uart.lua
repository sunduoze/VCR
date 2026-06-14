-- =====================================================
-- 示例5: 串口通信
-- =====================================================
-- 演示: apiSend, apiSetCb, apiUnsetCb
-- 注意: 需要先连接设备并选择设备
-- 合并自: 05_uart.lua + 05_uart_test.lua

print('=== 串口通信示例 ===')
print('[提示] 请先在界面选择设备后点击运行')

-- 注册串口接收回调
apiSetCb('uart', function(data)
    print('[RX]', data)
    print('[HEX]', string.toHex(data))
end)

-- 所有发送/等待操作必须在协程中执行
sys.taskInit(function()
    -- ----- 1. AT 命令测试 -----
    print('\n--- AT 命令测试 ---')
    print('发送: AT')
    apiSend('uart', 'AT\r\n')
    sys.wait(500)

    print('发送: ATI')
    apiSend('uart', 'ATI\r\n')
    sys.wait(500)

    -- ----- 2. 字符串发送测试 -----
    print('\n--- 字符串发送测试 ---')
    local testData = 'Hello UART!\r\n'
    print('发送:', string.toHex(testData))
    apiSend('uart', testData)
    sys.wait(1000)

    -- ----- 3. 第二帧 + 取消回调 -----
    print('发送: Second frame')
    apiSend('uart', 'Second frame\r\n')
    sys.wait(1000)

    print('取消回调')
    apiUnsetCb('uart')
    sys.wait(200)

    print('\n串口通信示例完成')
end)

print('串口任务已在后台运行')
