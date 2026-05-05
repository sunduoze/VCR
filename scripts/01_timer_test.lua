-- 定时器测试脚本
-- 演示 sys.taskInit + sys.wait 的正确用法

print("=== Timer Test Script ===")

sys.taskInit(function()
    print("Task started")
    
    for i = 1, 5 do
        print("Count: " .. i)
        sys.wait(1000)  -- 等待 1 秒
    end
    
    print("Task completed!")
end)

print("Script loaded (task running in background)")
