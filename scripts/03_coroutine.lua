-- =====================================================
-- 示例3: 协程与 sys.wait / 任务调度
-- =====================================================
-- 演示: sys.taskInit, sys.wait, 多任务并发
-- 合并自: 03_coroutine.lua + 01_timer_test.lua

print("=== 协程与任务调度示例 ===")

-- ----- 1. 单任务基础 -----
print("\n[1] 基础协程任务")
sys.taskInit(function()
    print("  任务开始")
    sys.wait(1000)
    print("  1 秒后继续")
    sys.wait(500)
    print("  再过 0.5 秒")
    print("  任务完成")
end)

-- ----- 2. 循环计数任务 -----
print("\n[2] 循环计数任务")
sys.taskInit(function()
    for i = 1, 5 do
        print("  Count:", i)
        sys.wait(1000)
    end
    print("  循环计数完成")
end)

-- ----- 3. 并行多任务 -----
print("\n[3] 并行多任务 (A 每300ms, B 每400ms)")
sys.taskInit(function()
    for i = 1, 3 do
        print("  任务A - 步骤", i)
        sys.wait(300)
    end
    print("  任务A 完成")
end)

sys.taskInit(function()
    for i = 1, 3 do
        print("  任务B - 步骤", i)
        sys.wait(400)
    end
    print("  任务B 完成")
end)

print("\n协程任务已全部创建 (异步执行)")
