-- =====================================================
-- 示例3: 协程与 sys.wait
-- =====================================================
-- 演示: sys.taskInit, sys.wait, coroutine

print("=== 协程示例 ===")

-- 创建一个协程任务
sys.taskInit(function()
    print("任务开始")

    -- 等待 1 秒
    print("等待 1 秒...")
    sys.wait(1000)
    print("1 秒后继续")

    -- 等待 0.5 秒
    sys.wait(500)
    print("再过 0.5 秒")

    -- 任务结束
    print("任务完成")
end)

print("协程任务已创建 (异步执行)")

-- 另一个协程演示: 模拟多任务
sys.taskInit(function()
    for i = 1, 3 do
        print("任务A - 步骤", i)
        sys.wait(300)
    end
    print("任务A 完成")
end)

sys.taskInit(function()
    for i = 1, 3 do
        print("任务B - 步骤", i)
        sys.wait(400)
    end
    print("任务B 完成")
end)
