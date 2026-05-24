# -*- coding: utf-8 -*-
from PIL import Image
import sys

# 读取原始logo
logo_path = r'D:\AI\upper_computer_tools\VCR\assets\images\vcr_logo.png'
ico_path = r'D:\AI\upper_computer_tools\VCR\windows\runner\resources\app_icon.ico'

try:
    img = Image.open(logo_path).convert('RGBA')
    print(f'Loaded logo: {img.size}, Mode: {img.mode}')
    
    # 创建多种尺寸的图标
    sizes = [256, 128, 64, 48, 32, 16]
    icon_images = []
    for size in sizes:
        resized = img.resize((size, size), Image.LANCZOS)
        icon_images.append(resized)
    
    # 保存为ico
    img256 = img.resize((256, 256), Image.LANCZOS)
    img256.save(ico_path, format='ICO', sizes=[(s, s) for s in sizes])
    
    print(f"Icon generated successfully!")
    print(f"Source: {logo_path}")
    print(f"Output: {ico_path}")
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
