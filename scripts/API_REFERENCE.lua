-- =====================================================
-- API 快速参考
-- =====================================================

-- ==================== 日志 API ====================
-- print(...)                          -- 打印到日志缓冲区
-- log.trace(tag, ...)                 -- trace级别日志
-- log.debug(tag, ...)                 -- debug级别日志
-- log.info(tag, ...)                  -- info级别日志
-- log.warn(tag, ...)                  -- warn级别日志
-- log.error(tag, ...)                 -- error级别日志
-- log.fatal(tag, ...)                 -- fatal级别日志

-- ==================== 字符串扩展 ====================
-- string.toHex(str) -> string         -- 字符串转十六进制
-- string.fromHex(hex) -> string       -- 十六进制转字符串
-- string.utf8Len(str) -> number       -- UTF-8字符数
-- string.split(str, sep) -> table     -- 字符串分割
-- string.urlEncode(str) -> string     -- URL编码

-- ==================== 定时器 API ====================
-- sys.timerStart(fn, ms, ...) -> id   -- 启动单次定时器
-- sys.timerLoopStart(fn, ms, ...) -> id -- 启动循环定时器
-- sys.timerStop(id)                   -- 停止定时器
-- sys.timerStopAll(fn)                -- 停止所有同名定时器
-- sys.timerIsActive(id) -> bool       -- 检查定时器状态

-- ==================== 协程 API ====================
-- sys.taskInit(fn, ...)               -- 创建协程任务
-- sys.wait(ms)                        -- 协程内等待
-- sys.waitUntil(event, ms) -> bool, ... -- 等待事件
-- sys.waitUntilExt(event, ms) -> ...  -- 扩展等待

-- ==================== 消息 API ====================
-- sys.subscribe(event, callback)      -- 订阅事件
-- sys.unsubscribe(event, callback)    -- 取消订阅
-- sys.publish(event, ...)             -- 发布事件

-- ==================== 串口 API ====================
-- apiSend(channel, data) -> bool      -- 发送数据到通道
-- apiSendUartData(data) -> bool       -- 发送串口数据
-- apiSetCb(channel, callback)         -- 注册回调
-- apiUnsetCb(channel, callback)       -- 注销回调

-- ==================== 硬件流控制 API ====================
-- apiSerialSetDTR(level) -> bool      -- 设置 DTR 信号 (true=HIGH, false=LOW)
-- apiSerialSetRTS(level) -> bool      -- 设置 RTS 信号 (true=HIGH, false=LOW)
-- apiSerialGetCTS() -> bool           -- 读取 CTS 信号状态
-- apiSerialGetDSR() -> bool           -- 读取 DSR 信号状态

-- ==================== UI API ====================
-- apiInputBox(prompt, default, title) -> string -- 弹出输入框
-- apiGetPath() -> string              -- 获取软件路径
-- apiPrintLog(str)                    -- 输出到日志缓冲区
-- apiAddPoint(value, line)            -- 添加图表数据点

-- ==================== 全局回调 ====================
-- uartReceive(data)                   -- 串口接收回调 (需定义)
-- tiggerCB(id, msgType, data)         -- 定时器/通道触发入口

-- ==================== 注意事项 ====================
-- 1. os 模块不可用 (mlua lua53 未启用)
-- 2. 协程内使用 sys.wait, 不能在普通函数中使用
-- 3. apiInputBox 会阻塞当前协程, 需在协程内调用
-- 4. 串口发送前需在界面选择设备ID
-- 5. 定时器ID范围: 0 ~ 0x1FFFFFFF (任务) / 0x1FFFFFFF+ (消息)
