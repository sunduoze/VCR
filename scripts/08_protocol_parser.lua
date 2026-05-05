-- =====================================================
-- 示例8: 完整的串口协议解析器
-- =====================================================
-- 演示: 协议解析、校验、回调触发
-- 假设协议格式: [HEAD][LEN][CMD][DATA...][CHECKSUM]
-- HEAD: 0xAA
-- LEN: 数据长度(不含HEAD和CHECKSUM)
-- CMD: 命令字
-- DATA: N字节
-- CHECKSUM: 累加和取低字节

print("=== 协议解析器示例 ===")

local RxState = {
    WAIT_HEAD = 0,
    WAIT_LEN = 1,
    WAIT_DATA = 2,
}

local rxState = RxState.WAIT_HEAD
local rxLen = 0
local rxCmd = 0
local rxData = {}
local rxChecksum = 0

-- 协议解析状态机
local function parseProtocol(byte)
    if rxState == RxState.WAIT_HEAD then
        if byte == 0xAA then
            rxState = RxState.WAIT_LEN
            rxData = {}
            rxChecksum = 0
        end

    elseif rxState == RxState.WAIT_LEN then
        rxLen = byte
        rxChecksum = byte
        if rxLen > 0 then
            rxState = RxState.WAIT_DATA
        else
            rxState = RxState.WAIT_HEAD
        end

    elseif rxState == RxState.WAIT_DATA then
        table.insert(rxData, byte)
        rxChecksum = (rxChecksum + byte) & 0xFF

        if #rxData >= rxLen - 1 then  -- LEN包含CMD
            -- 最后一个字节是校验
            rxState = RxState.WAIT_HEAD

            -- 验证校验 (简化示例)
            local expectedCsum = rxChecksum
            -- if byte == expectedCsum then
            --     sys.publish("PROTOCOL_RX", rxCmd, rxData)
            -- end
            print("协议解析完成 CMD:", string.format("0x%02X", rxCmd))
        end
    end
end

-- 注册串口接收回调
apiSetCb("uart", function(data)
    for i = 1, #data do
        parseProtocol(data:byte(i))
    end
end)

-- 订阅协议事件
sys.subscribe("PROTOCOL_RX", function(cmd, data)
    print("收到协议帧:")
    print("  CMD:", string.format("0x%02X", cmd))
    print("  DATA:", table.concat(data, ", "))
end)

-- 构造并发送协议帧
local function sendProtocol(cmd, data)
    local frame = string.char(0xAA)
    local len = #data + 1  -- CMD + DATA
    frame = frame .. string.char(len)
    frame = frame .. string.char(cmd)

    local csum = len + cmd
    for _, b in ipairs(data) do
        frame = frame .. string.char(b)
        csum = (csum + b) & 0xFF
    end
    frame = frame .. string.char(csum)

    apiSend("uart", frame)
    print("发送协议帧:", string.toHex(frame))
end

-- 示例: 发送心跳请求
sys.timerLoopStart(function()
    sendProtocol(0x01, {})  -- CMD=0x01, 无数据
end, 3000)

print("协议解析器已启动")
