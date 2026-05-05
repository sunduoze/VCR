-- =====================================================
-- 示例2: 定时器使用
-- =====================================================
-- 演示: sys.timerStart, sys.timerStop, sys.timerLoopStart

print("=== 定时器示例 ===")

-- 单次定时器: 1秒后执行
local timerId1 = sys.timerStart(function()
    print("单次定时器触发 (1秒后)")
end, 1000)

print("创建单次定时器, ID:", timerId1)

-- 循环定时器: 每500ms执行一次
local count = 0
local timerId2 = sys.timerLoopStart(function()
    count = count + 1
    print("循环定时器触发, 计数:", count)

    -- 5次后停止
    if count >= 5 then
        print("停止循环定时器")
        sys.timerStop(timerId2)
    end
end, 500)

print("创建循环定时器, ID:", timerId2)

-- 检查定时器是否活跃
print("定时器", timerId1, "活跃?", sys.timerIsActive(timerId1) and "是" or "否")
