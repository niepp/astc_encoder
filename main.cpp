#define _CRT_SECURE_NO_WARNINGS
#define _WIN32_WINNT 0x600

#include <string>
#include <iostream>
#include <sstream>

#include <d3d11.h>
#include <d3dcompiler.h>
#include <directxmath.h>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "d3dcompiler.lib")
#pragma comment(lib, "dxguid.lib")

#define STB_IMAGE_IMPLEMENTATION

#include "stb_image.h"
#include "encode_astc.h"
#include "save_astc.h"

typedef struct _constantBufferStruct
{
	DirectX::XMFLOAT4X4 m;
	DirectX::XMFLOAT4X4 vp;
} ConstantBufferStruct;


typedef struct _vertexPositionColor
{
	DirectX::XMFLOAT3 pos;
	DirectX::XMFLOAT2 uv;
} VertexPositionColor;


typedef struct  _renderDevice
{
	IDXGISwapChain* pSwapChain;
	ID3D11Device* pd3dDevice;
	ID3D11DeviceContext* pDeviceContext;
	ID3D11RenderTargetView* pRenderTarget;
	ID3D11DepthStencilView* pDepthStencilView;
} RenderDevice;


typedef struct _renderContext
{
	ID3D11VertexShader*      pVertexShader;
	ID3D11PixelShader*       pPixelShader;
	ID3D11Buffer*            pVertexConstantBuffer;
	ID3D11Buffer*            pPixelConstantBuffer;
	ID3D11InputLayout*       pInputLayout;
	ID3D11Buffer*            pVertexBuffer;
	ID3D11Buffer*            pIndexBuffer;
	ID3D11RasterizerState*	 pRasterState;
	int indexCount;
} RenderContext;


ID3D11Texture2D* load_tex(ID3D11Device* pd3dDevice, const char* tex_path, bool bSRGB)
{
	int xsize = 0;
	int ysize = 0;
	int components = 0;
	stbi_uc* image = stbi_load(tex_path, &xsize, &ysize, &components, STBI_rgb_alpha);
	if (image == nullptr) {
		// if we haven't returned, it's because we failed to load the file.
		printf("Failed to load image %s\nReason: %s\n", tex_path, stbi_failure_reason());
		return nullptr;
	}

	// create texture
	D3D11_TEXTURE2D_DESC TexDesc;
	TexDesc.Width = xsize;		// grid size of the waves, rows
	TexDesc.Height = ysize;		// grid size of the waves, colums
	TexDesc.MipLevels = 1;
	TexDesc.ArraySize = 1;
	TexDesc.Format = bSRGB ? DXGI_FORMAT_R8G8B8A8_UNORM_SRGB : DXGI_FORMAT_R8G8B8A8_UNORM;
	TexDesc.SampleDesc.Count = 1;
	TexDesc.SampleDesc.Quality = 0;
	TexDesc.Usage = D3D11_USAGE_DEFAULT;
	TexDesc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
	TexDesc.CPUAccessFlags = 0;
	TexDesc.MiscFlags = 0;

	D3D11_SUBRESOURCE_DATA InitialData;
	InitialData.pSysMem = image;
	InitialData.SysMemPitch = xsize * 4;
	InitialData.SysMemSlicePitch = xsize * ysize * 4;

	ID3D11Texture2D* pTex = nullptr;
	pd3dDevice->CreateTexture2D(&TexDesc, &InitialData, &pTex);

	return pTex;

}

HRESULT create_device_swapchain(HWND hwnd, IDXGISwapChain*& pSwapChain, ID3D11Device*& pd3dDevice, ID3D11DeviceContext*& pDeviceContext)
{
	DXGI_SWAP_CHAIN_DESC desc;
	ZeroMemory(&desc, sizeof(DXGI_SWAP_CHAIN_DESC));
	desc.BufferDesc.Width = 800;
	desc.BufferDesc.Height = 600;
	desc.BufferDesc.RefreshRate.Denominator = 0;
	desc.BufferDesc.RefreshRate.Numerator = 0;
	desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
	desc.SampleDesc.Count = 1;      //multisampling setting
	desc.SampleDesc.Quality = 0;    //vendor-specific flag
	desc.BufferUsage = DXGI_USAGE_UNORDERED_ACCESS;		//DXGI_USAGE_UNORDERED_ACCESS;
	desc.BufferCount = 1;
	desc.OutputWindow = hwnd;
	desc.Windowed = TRUE;
	desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
	desc.Flags = 0;

	// This flag adds support for surfaces with a color-channel ordering different
	// from the API default. It is required for compatibility with Direct2D.
	UINT deviceFlags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;

#if defined(DEBUG) || defined(_DEBUG)
	deviceFlags |= D3D11_CREATE_DEVICE_DEBUG;
#endif

	D3D_FEATURE_LEVEL featureLevel = D3D_FEATURE_LEVEL::D3D_FEATURE_LEVEL_11_0;

	HRESULT hr = D3D11CreateDeviceAndSwapChain(
		nullptr,
		D3D_DRIVER_TYPE::D3D_DRIVER_TYPE_HARDWARE,
		nullptr,
		deviceFlags,
		0,
		0,
		D3D11_SDK_VERSION,
		&desc,
		&pSwapChain,
		&pd3dDevice,
		&featureLevel,
		&pDeviceContext);

	if (FAILED(hr))	{
		return hr;
	}

	// Verify compute shader is supported
	if (pd3dDevice->GetFeatureLevel() < D3D_FEATURE_LEVEL_11_0)
	{
		D3D11_FEATURE_DATA_D3D10_X_HARDWARE_OPTIONS hwopts = { 0 };
		(void)pd3dDevice->CheckFeatureSupport(D3D11_FEATURE_D3D10_X_HARDWARE_OPTIONS, &hwopts, sizeof(hwopts));
		if (!hwopts.ComputeShaders_Plus_RawAndStructuredBuffers_Via_Shader_4_x)
		{
			pd3dDevice->Release();
			printf("DirectCompute is not supported by this device\n");
			return -1;
		}
	}

	return hr;

}

std::string get_file_extension(const char* file_path)
{
	const char* ext = strrchr(file_path, '.');
	if (ext != NULL) {
		return std::string(ext + 1);
	}
	return "";
}

void strip_file_extension(std::string &file_path)
{
	const char* str = file_path.c_str();
	char* ext = const_cast<char*>(strrchr(str, '.'));
	if (ext != nullptr) {
		*ext = 0;
		file_path = str;
	}
}


bool parse_cmd(int argc, char** argv, encode_option& option)
{
	auto func_arg_value = [](int index, int argc, char** argv, bool &ret) -> bool {
		if (index < argc && std::isdigit(*(argv[index])) > 0) {
			ret = (argv[index] == std::string("0"));
			return true;
		}
		return false;
	};

	for (int i = 2; i < argc; ++i) {
		if (argv[i] == std::string("-4x4")) {
			if (!func_arg_value(i + 1, argc, argv, option.is4x4)) {
				return false;
			}
		}
		else if (argv[i] == std::string("-norm")) {
			if (!func_arg_value(i + 1, argc, argv, option.is_normal_map)) {
				return false;
			}
		}
		else if (argv[i] == std::string("-fast")) {
			if (!func_arg_value(i + 1, argc, argv, option.fast)) {
				return false;
			}
		}
		else if (argv[i] == std::string("-alpha")) {
			if (!func_arg_value(i + 1, argc, argv, option.has_alpha)) {
				return false;
			}
		}
		else if (argv[i] == std::string("-mips")) {
			if (!func_arg_value(i + 1, argc, argv, option.has_mips)) {
				return false;
			}
		}
	}
	return true;
}

int main(int argc, char** argv)
{
	//argv[1] = "F:/work_astc/astc_cs/leaf.png";
	//argv[2] = "-4x4";
	//argv[3] = "1";
	//argv[4] = "-fast";
	//argv[5] = "1";
	//argv[6] = "-norm";
	//argv[7] = "0";

	
	if (argc < 2) {
		return -1;
	}

	encode_option option;
	if (!parse_cmd(argc, argv, option)) {
		return -1;
	}

	option.is4x4 = true;
	option.has_alpha = true;
	option.has_mips = true;

	int cBlockDimX = option.is4x4 ? 4 : 6;
	int cBlockDimY = option.is4x4 ? 4 : 6;

	HWND hwnd = ::GetDesktopWindow();

	// setting up device
	IDXGISwapChain* pSwapChain = nullptr;
	ID3D11Device* pd3dDevice = nullptr;
	ID3D11DeviceContext* pDeviceContext = nullptr;
	HRESULT hr = create_device_swapchain(hwnd, pSwapChain, pd3dDevice, pDeviceContext);
	if (FAILED(hr))	{
		return hr;
	}

	std::string src_tex = argv[1];

	int DimSize = option.is4x4 ? 4 : 6;

	// shader resource view
	ID3D11Texture2D* pSrcTexture = load_tex(pd3dDevice, src_tex.c_str(), !option.is_normal_map);

	D3D11_TEXTURE2D_DESC TexDesc;
	pSrcTexture->GetDesc(&TexDesc);
	int TexWidth = TexDesc.Width;
	int TexHeight = TexDesc.Height;

	ID3D11Buffer* pOutBuf = encode_astc(pSwapChain, pd3dDevice, pDeviceContext, pSrcTexture, option);

	// save to file
	D3D11_BUFFER_DESC sbDesc;
	pOutBuf->GetDesc(&sbDesc);

	uint32_t bufLen = sbDesc.ByteWidth;
	uint8_t* pMemBuf = new uint8_t[bufLen];
	ZeroMemory(pMemBuf, bufLen);
	read_gpu(pd3dDevice, pDeviceContext, pOutBuf, pMemBuf, bufLen);

	std::string dst_tex(src_tex);
	strip_file_extension(dst_tex);
	dst_tex += ".astc";
	save_astc(dst_tex.c_str(), cBlockDimX, cBlockDimX, TexDesc.Width, TexDesc.Height, pMemBuf, bufLen);

	delete[] pMemBuf;
	pMemBuf = nullptr;

	system("pause");

	return 0;

}

