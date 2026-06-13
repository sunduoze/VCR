import re

def fix_device_api():
    with open("src/api/device_api.rs", "r", encoding="utf-8") as f:
        content = f.read()
    
    replacements = [
        ('    eprintln!("🧪 [DEBUG] connect_device() 开始");', '    log::debug!("🧪 [DEBUG] connect_device() 开始");'),
        ('    eprintln!("   - device_id: {}", device_id);', '    log::debug!("   - device_id: {}", device_id);'),
        ('    eprintln!("🧪 [DEBUG] 步骤 1: 调用 SESSIONS.connect()");', '    log::debug!("🧪 [DEBUG] 步骤 1: 调用 SESSIONS.connect()");'),
        ('    eprintln!("🧪 [DEBUG] 步骤 1 完成，结果: {:?}", connect_result.is_ok());', '    log::debug!("🧪 [DEBUG] 步骤 1 完成，结果: {:?}", connect_result.is_ok());'),
        ('            eprintln!("🧪 [DEBUG] 步骤 2: 标记设备为已连接");', '            log::debug!("🧪 [DEBUG] 步骤 2: 标记设备为已连接");'),
        ('            eprintln!("🧪 [DEBUG] 步骤 3: 启动接收循环");', '            log::debug!("🧪 [DEBUG] 步骤 3: 启动接收循环");'),
        ('            eprintln!("🧪 [DEBUG] 步骤 3 完成");', '            log::debug!("🧪 [DEBUG] 步骤 3 完成");'),
        ('            eprintln!("🧪 [DEBUG] 步骤 4: 应用硬件流控制设置");', '            log::debug!("🧪 [DEBUG] 步骤 4: 应用硬件流控制设置");'),
        ('                    eprintln!("🧪 [DEBUG] 步骤 4a: 解析硬件流控制设置");', '                    log::debug!("🧪 [DEBUG] 步骤 4a: 解析硬件流控制设置");'),
        ('                    eprintln!("   - DTR: {}", parts[7]);', '                    log::debug!("   - DTR: {}", parts[7]);'),
        ('                    eprintln!("   - RTS: {}", parts[8]);', '                    log::debug!("   - RTS: {}", parts[8]);'),
        ('                    eprintln!("   - BREAK: {}", parts[9]);', '                    log::debug!("   - BREAK: {}", parts[9]);'),
        ('                        eprintln!("🧪 [DEBUG] 步骤 4b: 设置 DTR");', '                        log::debug!("🧪 [DEBUG] 步骤 4b: 设置 DTR");'),
        ('                        eprintln!("🧪 [DEBUG] 步骤 4c: 设置 RTS");', '                        log::debug!("🧪 [DEBUG] 步骤 4c: 设置 RTS");'),
        ('                        eprintln!("🧪 [DEBUG] 步骤 4d: 设置 BREAK");', '                        log::debug!("🧪 [DEBUG] 步骤 4d: 设置 BREAK");'),
        ('            eprintln!("🧪 [DEBUG] 步骤 4 完成");', '            log::debug!("🧪 [DEBUG] 步骤 4 完成");'),
        ('            eprintln!("🧪 [DEBUG] connect_device() 成功完成");', '            log::debug!("🧪 [DEBUG] connect_device() 成功完成");'),
        ('            eprintln!("🧪 [DEBUG] connect_device() 失败: {:?}", e);', '            log::error!("🧪 [DEBUG] connect_device() 失败: {:?}", e);'),
    ]
    
    for old, new in replacements:
        if old not in content:
            print(f"WARNING: not found: {old[:60]}...")
        content = content.replace(old, new)
    
    with open("src/api/device_api.rs", "w", encoding="utf-8", newline="\r\n") as f:
        f.write(content)
    
    remaining = re.findall(r'(?:println!|eprintln!)', content)
    print(f"device_api.rs: {len(remaining)} remaining direct prints")
    if remaining:
        for line in content.split('\n'):
            if 'println!' in line or 'eprintln!' in line:
                print(f"  REMAINING: {line.strip()[:100]}")

def fix_debug_api():
    with open("src/api/debug_api.rs", "r", encoding="utf-8") as f:
        content = f.read()
    
    replacements = [
        ('        println!("🧪 [DEBUG] 启动接收循环: {}");', '        log::info!("🧪 [DEBUG] 启动接收循环: {}");'),
        ('        println!("🧪 [DEBUG] 接收循环已存在: {}");', '        log::info!("🧪 [DEBUG] 接收循环已存在: {}");'),
        ('                    eprintln!("🧪 [DEBUG] [数据链路] 步骤1: 收到数据: {} 字节", data.len());',
         '                    log::debug!("🧪 [DEBUG] [数据链路] 步骤1: 收到数据: {} 字节", data.len());'),
        ('                    println!("🧪 [DEBUG] 收到空数据，继续等待...");',
         '                    log::debug!("🧪 [DEBUG] 收到空数据，继续等待...");'),
        ('                    println!("🧪 [DEBUG] 接收超时，继续等待...");',
         '                    log::debug!("🧪 [DEBUG] 接收超时，继续等待...");'),
        ('                    println!("🧪 [DEBUG] 设备断开连接: {:?}", e);',
         '                    log::warn!("🧪 [DEBUG] 设备断开连接: {:?}", e);'),
        ('                            eprintln!("🧪 [DEBUG] [数据链路] 步骤2: 解析成功, 通道数: {}");',
         '                            log::debug!("🧪 [DEBUG] [数据链路] 步骤2: 解析成功, 通道数: {}");'),
        ('                            eprintln!("🧪 [DEBUG] [数据链路] 步骤3: 数据已存储到 PLOT_DATA, pts={:.0}", counter);',
         '                            log::debug!("🧪 [DEBUG] [数据链路] 步骤3: 数据已存储到 PLOT_DATA, pts={:.0}", counter);'),
        ('                            eprintln!("🧪 [DEBUG] [数据链路] 步骤2: 解析失败: {:?}", line);',
         '                            log::warn!("🧪 [DEBUG] [数据链路] 步骤2: 解析失败: {:?}", line);'),
    ]
    
    for old, new in replacements:
        if old not in content:
            print(f"WARNING: not found in debug_api.rs: {old[:60]}...")
        content = content.replace(old, new)
    
    with open("src/api/debug_api.rs", "w", encoding="utf-8", newline="\r\n") as f:
        f.write(content)
    
    remaining = re.findall(r'(?:println!|eprintln!)', content)
    print(f"debug_api.rs: {len(remaining)} remaining direct prints")
    if remaining:
        for line in content.split('\n'):
            if 'println!' in line or 'eprintln!' in line:
                print(f"  REMAINING: {line.strip()[:100]}")

def fix_gpu_api():
    with open("src/api/gpu_api.rs", "r", encoding="utf-8") as f:
        content = f.read()
    
    content = content.replace(
        '    eprintln!("[GPU] ========= GPU Init Starting =========");',
        '    log::info!("[GPU] ========= GPU Init Starting =========");')
    # Remove duplicate eprintln! (already has log::info! above it)
    content = content.replace(
        '            eprintln!("[GPU] GPU renderer initialized successfully");',
        '')
    # This leaves an extra blank line, clean up double blank lines
    content = content.replace('\n\n\n', '\n\n')
    # Remove duplicate eprintln! (already has log::error! above it)
    content = content.replace(
        '            eprintln!("{}", error_msg);', '')
    content = content.replace('\n\n\n', '\n\n')
    
    with open("src/api/gpu_api.rs", "w", encoding="utf-8", newline="\r\n") as f:
        f.write(content)
    
    remaining = re.findall(r'(?:println!|eprintln!)', content)
    print(f"gpu_api.rs: {len(remaining)} remaining direct prints")

def fix_plot_api():
    with open("src/api/plot_api.rs", "r", encoding="utf-8") as f:
        content = f.read()
    
    old = '    eprintln!("🧪 [DEBUG] [数据链路] 步骤4: Dart 请求数据: device={}, channel={}, 返回 {} 个点", device_id, channel, result.len());'
    new = '    log::debug!("🧪 [DEBUG] [数据链路] 步骤4: Dart 请求数据: device={}, channel={}, 返回 {} 个点", device_id, channel, result.len());'
    
    if old not in content:
        print(f"WARNING: not found in plot_api.rs: {old[:60]}...")
    content = content.replace(old, new)
    
    with open("src/api/plot_api.rs", "w", encoding="utf-8", newline="\r\n") as f:
        f.write(content)
    
    remaining = re.findall(r'(?:println!|eprintln!)', content)
    print(f"plot_api.rs: {len(remaining)} remaining direct prints")

fix_device_api()
fix_debug_api()
fix_gpu_api()
fix_plot_api()
print("Done!")
