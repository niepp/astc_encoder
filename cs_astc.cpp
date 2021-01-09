#define WIDTH 1280
#define HEIGHT 800

#define _CRT_SECURE_NO_WARNINGS
#define _WIN32_WINNT 0x600
#include <stdio.h>
#include <string>

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


ID3D11Texture2D* load_tex(ID3D11Device* pd3dDevice, const char* tex_path)
{
	int xsize = 0;
	int ysize = 0;
	int components = 0;
	stbi_uc* image = stbi_load(tex_path, &xsize, &ysize, &components, STBI_rgb_alpha);
	if (image == nullptr)
	{
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
	TexDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
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


HWND create_window(const char* window_title, int width, int height)
{
	const char class_name[] = "wndclass";
	HINSTANCE instance = GetModuleHandle(nullptr);

	// Register the window class
	WNDCLASSEX wc = {
		sizeof(WNDCLASSEX), CS_CLASSDC, DefWindowProc, 0, 0,
		instance, nullptr, nullptr, nullptr, nullptr,
		class_name, nullptr
	};

	RegisterClassEx(&wc);

	// Create the application's window
	DWORD style = WS_OVERLAPPEDWINDOW | WS_BORDER | WS_CAPTION | WS_CLIPCHILDREN | WS_CLIPSIBLINGS | WS_VISIBLE | WS_SYSMENU;
	HWND hwnd = CreateWindow(class_name, window_title,
		style,
		0, 0,
		width, height,
		nullptr, nullptr,
		instance, nullptr);

	return hwnd;

}

HRESULT create_device_swapchain(HWND hwnd, int width, int height, IDXGISwapChain*& pSwapChain, ID3D11Device*& pd3dDevice, ID3D11DeviceContext*& pDeviceContext)
{
	DXGI_SWAP_CHAIN_DESC desc;
	ZeroMemory(&desc, sizeof(DXGI_SWAP_CHAIN_DESC));
	desc.BufferDesc.Width = width;
	desc.BufferDesc.Height = height;
	desc.BufferDesc.RefreshRate.Denominator = 0;
	desc.BufferDesc.RefreshRate.Numerator = 0;
	desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
	desc.SampleDesc.Count = 1;      //multisampling setting
	desc.SampleDesc.Quality = 0;    //vendor-specific flag
	desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;		//DXGI_USAGE_UNORDERED_ACCESS;
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

	if (FAILED(hr))
	{
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


int main()
{

	const int cFrameRate = 30;
	const int cWidth = 1280;
	const int cHeight = 800;

	const int cBlockDimX = 4;
	const int cBlockDimY = 4;
	const int cNumthreadX = 8; // same to compute shader [numthreads(8, 8, 1)]
	const int cNumthreadY = 8;

	HWND hwnd = create_window("cs", cWidth, cHeight);

	float aspectRatio = 1.0f * cWidth / cHeight;

	// setting up device
	IDXGISwapChain* pSwapChain = nullptr;
	ID3D11Device* pd3dDevice = nullptr;
	ID3D11DeviceContext* pDeviceContext = nullptr;
	HRESULT hr = create_device_swapchain(hwnd, cWidth, cHeight, pSwapChain, pd3dDevice, pDeviceContext);
	if (FAILED(hr))
	{
		return hr;
	}

	//std::string tcase = "fruit";
	std::string tcase = "puffin";
	//std::string tcase = "blooming";

	std::string src_tex = "F:/work_astc/astc_quality/testimg/";
//	std::string dst_tex = "F:/work_astc/astc_quality/encode/";
	std::string dst_tex = "F:/work_astc/ASTC_preview/Assets/Resources/";

	// shader resource view
	ID3D11Texture2D* pCubeTexture = load_tex(pd3dDevice, (src_tex + tcase + ".png").c_str() );

	D3D11_TEXTURE2D_DESC TexDesc;
	pCubeTexture->GetDesc(&TexDesc);

	ID3D11Buffer* pOutBuf = encode_astc(pSwapChain, pd3dDevice, pDeviceContext, pCubeTexture);
	
	// save to file
	uint32_t bufLen = 16 * ((TexDesc.Height + cBlockDimY - 1) / cBlockDimY) * ((TexDesc.Width + cBlockDimX - 1) / cBlockDimX);
	uint8_t* pMemBuf = new uint8_t[bufLen];
	ZeroMemory(pMemBuf, bufLen);
	read_gpu(pd3dDevice, pDeviceContext, pOutBuf, pMemBuf, bufLen);

	save_astc((dst_tex + tcase + "_cs.astc").c_str(), cBlockDimX, cBlockDimX, TexDesc.Width, TexDesc.Height, pMemBuf);

	return 0;

}

