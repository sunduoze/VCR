-- =====================================================
-- 示例13: 硬件流控制 (Hardware Flow Control)
-- =====================================================
-- 演示: apiSerialSetDTR, apiSerialSetRTS, apiSerialGetCTS, apiSerialGetDSR
--
-- 硬件连接 (Arduino UNO/Nano):
--   PC UART RX  <-- Arduino TX  (D1)
--   PC UART TX  --> Arduino RX  (D0)
--   PC CTS      <-- Arduino RTS (D12)  [Arduino 输出 -> PC 输入]
--   PC RTS      --> Arduino CTS (D11)  [PC 输出 -> Arduino 输入]
--   PC DTR      --> Arduino DSR (D13)  [PC 输出 -> Arduino 输入]
--   PC DSR      <-- Arduino DTR (D7)   [Arduino 输出 -> PC 输入]
--   GND         <-> GND
--
-- 注意: Arduino 端需烧录配套 flow_control_test.ino
-- 注意: 设备创建时流控选择 Hardware (硬件流控)

print('=== 硬件流控制测试 ===')
print('请确保:')
print('  1. 已连接设备 (流控选择 Hardware)')
print('  2. Arduino 已烧录 flow_control_test.ino')
print('  3. 已在界面选择此设备')

-- 注册串口接收回调
apiSetCb('uart', function(data)
    print('[RX] ' .. data)
end)

-- 所有测试必须在协程中运行
sys.taskInit(function()
    -- =====================================================
    -- 测试1: 读取初始信号状态
    -- =====================================================
    print('\n--- 测试1: 读取初始信号状态 ---')
    local cts = apiSerialGetCTS()
    local dsr = apiSerialGetDSR()
    print(string.format('CTS: %s  (应取决于 Arduino D12 状态)', tostring(cts)))
    print(string.format('DSR: %s  (应取决于 Arduino D7 状态)', tostring(dsr)))

    -- =====================================================
    -- 测试2: 控制 DTR 信号
    -- =====================================================
    print('\n--- 测试2: 控制 DTR 信号 ---')
    print('DTR -> HIGH')
    apiSerialSetDTR(true)
    sys.wait(100)
    print(string.format('Arduino DSR (D7 LED) 应点亮, 本地读取 DSR=%s', tostring(apiSerialGetDSR())))

    print('DTR -> LOW')
    apiSerialSetDTR(false)
    sys.wait(100)
    print(string.format('Arduino DSR (D7 LED) 应熄灭, 本地读取 DSR=%s', tostring(apiSerialGetDSR())))

    -- =====================================================
    -- 测试3: 控制 RTS 信号
    -- =====================================================
    print('\n--- 测试3: 控制 RTS 信号 ---')
    print('RTS -> HIGH')
    apiSerialSetRTS(true)
    sys.wait(100)
    print('Arduino CTS (D11 LED) 应点亮')

    print('RTS -> LOW')
    apiSerialSetRTS(false)
    sys.wait(100)
    print('Arduino CTS (D11 LED) 应熄灭')

    -- =====================================================
    -- 测试4: 读取 Arduino 控制的 CTS/DSR
    -- =====================================================
    print('\n--- 测试4: 读取 Arduino 端信号 ---')
    -- 发送命令让 Arduino 拉高 RTS (连接到 PC CTS)
    apiSend('uart', 'RTS 1\r\n')
    sys.wait(200)
    print(string.format('CTS = %s (Arduino RTS=HIGH -> PC CTS 应为 true)', tostring(apiSerialGetCTS())))

    apiSend('uart', 'RTS 0\r\n')
    sys.wait(200)
    print(string.format('CTS = %s (Arduino RTS=LOW  -> PC CTS 应为 false)', tostring(apiSerialGetCTS())))

    -- 发送命令让 Arduino 拉高 DTR (连接到 PC DSR)
    apiSend('uart', 'DTR 1\r\n')
    sys.wait(200)
    print(string.format('DSR = %s (Arduino DTR=HIGH -> PC DSR 应为 true)', tostring(apiSerialGetDSR())))

    apiSend('uart', 'DTR 0\r\n')
    sys.wait(200)
    print(string.format('DSR = %s (Arduino DTR=LOW  -> PC DSR 应为 false)', tostring(apiSerialGetDSR())))

    -- =====================================================
    -- 测试5: 命令 Arduino 回显信号状态
    -- =====================================================
    print('\n--- 测试5: 查询 Arduino 端信号状态 ---')
    apiSend('uart', 'STATUS\r\n')

    -- =====================================================
    -- 测试6: LED 闪烁 (通过 DTR 控制 Arduino DSR LED)
    -- =====================================================
    print('\n--- 测试6: DTR 闪烁 3 次 ---')
    for i = 1, 3 do
        apiSerialSetDTR(true)
        sys.wait(300)
        apiSerialSetDTR(false)
        sys.wait(300)
        print(string.format('闪烁 %d/3', i))
    end

    -- =====================================================
    -- 测试7: 协程式持续监控信号变化
    -- =====================================================
    print('\n--- 测试7: 启动信号监控 (5秒) ---')
    print('尝试在 Arduino 端切换 RTS/DTR 观察变化...')

    local _last_cts = apiSerialGetCTS()
    local _last_dsr = apiSerialGetDSR()

    local elapsed = 0
    while elapsed < 5000 do
        local cts_now = apiSerialGetCTS()
        local dsr_now = apiSerialGetDSR()
        if cts_now ~= _last_cts or dsr_now ~= _last_dsr then
            print(string.format('[信号变化] CTS: %s -> %s, DSR: %s -> %s',
                tostring(_last_cts), tostring(cts_now),
                tostring(_last_dsr), tostring(dsr_now)))
            _last_cts = cts_now
            _last_dsr = dsr_now
        end
        sys.wait(50)
        elapsed = elapsed + 50
    end
    print('监控结束')

    print('\n=== 硬件流控制测试完成 ===')
end)
