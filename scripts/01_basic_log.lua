-- =====================================================
-- 示例1: 基础日志和字符串操作
-- =====================================================
-- 演示: print, log 模块, string 扩展方法

print("=== 基础日志示例 ===")

-- 日志级别: trace, debug, info, warn, error, fatal
log.trace("TAG", "这是一条 trace 日志")
log.debug("TAG", "这是一条 debug 日志")
log.info("TAG", "这是一条 info 日志")
log.warn("TAG", "这是一条 warn 日志")
log.error("TAG", "这是一条 error 日志")

-- 字符串转十六进制
local str = "Hello"
local hex = string.toHex(str)
print("原始字符串:", str)
print("十六进制:", hex)

-- 十六进制转字符串
local original = string.fromHex(hex)
print("还原字符串:", original)

-- UTF-8 字符串长度（中文字符）
local chinese = "你好世界"
print("字符串长度(字节):", #chinese)
print("UTF-8字符数:", string.utf8Len(chinese))

-- 字符串分割
local parts = string.split("a,b,c,d", ",")
print("分割结果:", table.concat(parts, " | "))

-- URL 编码
local url = string.urlEncode("你好 world")
print("URL编码:", url)
