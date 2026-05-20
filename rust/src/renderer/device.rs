// renderer/device.rs - DirectX 11 设备初始化

use windows::{
    core::*,
    Win32::Foundation::*,
    Win32::Graphics::Direct3D11::*,
    Win32::Graphics::Dxgi::*,
};

/// DirectX 11 设备封装
pub struct D3D11Device {
    pub device: ID3D11Device,
    pub context: ID3D11DeviceContext,
    pub feature_level: D3D_FEATURE_LEVEL,
}

impl D3D11Device {
    /// 初始化 DirectX 11 设备
    pub fn new() -> Result<Self> {
        unsafe {
            // 1. 创建 DXGI factory
            let dxgi_factory: IDXGIFactory1 = CreateDXGIFactory1()?;

            // 2. 枚举适配器，选择第一个支持 DirectX 11 的
            let mut adapter: Option<IDXGIAdapter> = None;
            let mut i = 0;
            while let Ok(a) = dxgi_factory.EnumAdapters(i) {
                // 检查适配器是否支持 DirectX 11
                let mut device = None;
                let mut feature_level = D3D_FEATURE_LEVEL_11_0;
                
                if D3D11CreateDevice(
                    &a,
                    D3D_DRIVER_TYPE_UNKNOWN,
                    HANDLE::default(),
                    D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                    Some(&[D3D_FEATURE_LEVEL_11_0]),
                    D3D11_SDK_VERSION,
                    Some(&mut device),
                    Some(&mut feature_level),
                    None,
                ).is_ok() {
                    adapter = Some(a);
                    break;
                }
                
                i += 1;
            }

            let adapter = adapter.ok_or(E_FAIL)?;

            // 3. 创建 DirectX 11 设备
            let mut device = None;
            let mut context = None;
            let mut feature_level = D3D_FEATURE_LEVEL_11_0;

            D3D11CreateDevice(
                &adapter,
                D3D_DRIVER_TYPE_UNKNOWN,
                HANDLE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                Some(&[D3D_FEATURE_LEVEL_11_0]),
                D3D11_SDK_VERSION,
                Some(&mut device),
                Some(&mut feature_level),
                Some(&mut context),
            )?;

            let device = device.ok_or(E_FAIL)?;
            let context = context.ok_or(E_FAIL)?;

            Ok(Self {
                device,
                context,
                feature_level,
            })
        }
    }

    /// 获取设备指针
    pub fn get_device(&self) -> &ID3D11Device {
        &self.device
    }

    /// 获取设备上下文指针
    pub fn get_context(&self) -> &ID3D11DeviceContext {
        &self.context
    }

    /// 检查特性等级
    pub fn get_feature_level(&self) -> D3D_FEATURE_LEVEL {
        self.feature_level
    }
}

/// 测试函数：初始化 DirectX 11 设备
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_d3d11_init() {
        let d3d_device = D3D11Device::new();
        assert!(d3d_device.is_ok(), "Failed to initialize DirectX 11 device");
        
        let d3d_device = d3d_device.unwrap();
        println!("DirectX 11 device initialized successfully");
        println!("Feature level: {:?}", d3d_device.get_feature_level());
    }
}
