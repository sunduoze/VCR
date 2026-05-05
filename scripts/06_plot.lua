-- =====================================================
-- 示例6: Plot 数据点绘图
-- =====================================================
-- 演示: apiAddPoint

print("=== Plot 数据绘图示例 ===")

local x = 0

-- 每100ms添加一个数据点
sys.timerLoopStart(function()
    x = x + 0.1

    -- 正弦波 (line 1)
    local y1 = math.sin(x) * 50 + 50
    apiAddPoint(y1, 1)

    -- 余弦波 (line 2)
    local y2 = math.cos(x) * 30 + 50
    apiAddPoint(y2, 2)

    -- 随机噪声 (line 3)
    local y3 = math.random() * 20 + 40
    apiAddPoint(y3, 3)
end, 100)

print("Plot 数据生成中...")
print("Line 1: 正弦波")
print("Line 2: 余弦波")
print("Line 3: 随机噪声")
