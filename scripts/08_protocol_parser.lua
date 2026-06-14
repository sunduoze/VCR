-- =====================================================
-- 示例8: 完整的串口协议解析器
-- =====================================================
-- 演示: 协议解析、校验、回调触发
-- 假设协议格式: [HEAD][LEN][CMD][DATA...][CHECKSUM]
-- HEAD: 0xAA
-- LEN: 数据长度 (CMD + DATA 的字节数)
-- CMD: 命令字
-- DATA: N-1 字节
-- CHECKSUM: 累加和取低字节 (覆盖 LEN+CMD+DATA)

print("=== 协议解析器示例 ===")

local RxState = {
    WAIT_HEAD = 0,
    WAIT_LEN = 1,
    WAIT_CMD = 2,
    WAIT_DATA = 3,
    WAIT_CHECKSUM = 4,
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
        rxChecksum = (rxChecksum + byte) & 0xFF
        if rxLen > 0 then
            rxState = RxState.WAIT_CMD
        else
            rxState = RxState.WAIT_HEAD
        end

    elseif rxState == RxState.WAIT_CMD then
        rxCmd = byte
        rxChecksum = (rxChecksum + byte) & 0xFF
        if rxLen > 1 then
            rxState = RxState.WAIT_DATA
        else
            rxState = RxState.WAIT_CHECKSUM
        end

    elseif rxState == RxState.WAIT_DATA then
        table.insert(rxData, byte)
        rxChecksum = (rxChecksum + byte) & 0xFF
        if #rxData >= rxLen - 1 then  -- CMD 已计入 LEN
            rxState = RxState.WAIT_CHECKSUM
        end

    elseif rxState == RxState.WAIT_CHECKSUM then
        rxState = RxState.WAIT_HEAD
        -- 验证校验和
        if byte == rxChecksum then
            print(string.format("协议解析完成 CMD: 0x%02X, DATA: [%s], 校验: OK",
                rxCmd, table.concat(rxData, ", ")))
        else
            print(string.format("校验失败: 期望=0x%02X 实际=0x%02X",
                rxChecksum, byte))
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
