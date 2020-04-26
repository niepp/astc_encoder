#define WIDTH 1280
#define HEIGHT 800

#define _CRT_SECURE_NO_WARNINGS
#define _WIN32_WINNT 0x600
#include <stdio.h>

#include <d3d11.h>
#include <d3dcompiler.h>
#include <directxmath.h>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "d3dcompiler.lib")
#pragma comment(lib, "dxguid.lib")

#define STB_IMAGE_IMPLEMENTATION

#include "stb_image.h"
#include "timer.h"
#include "encode_astc.h"

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


HRESULT create_cube_shader(ID3D11Device* pd3dDevice, ID3D11InputLayout*& pInputLayout, ID3D11VertexShader*& pVertexShader, ID3D11PixelShader*& pPixelShader)
{
	HRESULT hr = S_OK;

	// Compile shader
	ID3DBlob *vsBlob = nullptr;
	hr = compile_shader(L"CubeVertexShader.hlsl", "main", "vs_5_0", pd3dDevice, &vsBlob);
	if (FAILED(hr))
	{
		return -1;
	}

	char *code = (char*)vsBlob->GetBufferPointer();
	int len = (int)vsBlob->GetBufferSize();

	// Create vertex shader
	hr = pd3dDevice->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), nullptr, &pVertexShader);
	if (FAILED(hr))
	{
		return -1;
	}

	// create input layout
	D3D11_INPUT_ELEMENT_DESC iaDesc[] =
	{
		{ "POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT,
		0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0 },

		{ "TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT,
		0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0 },
	};

	hr = pd3dDevice->CreateInputLayout(
		iaDesc,
		_countof(iaDesc),
		vsBlob->GetBufferPointer(),
		vsBlob->GetBufferSize(),
		&pInputLayout);

	// Compile shader
	ID3DBlob *psBlob = nullptr;
	hr = compile_shader(L"CubePixelShader.hlsl", "main", "ps_5_0", pd3dDevice, &psBlob);
	if (FAILED(hr))
	{
		return -1;
	}

	// Create pixel shader
	hr = pd3dDevice->CreatePixelShader(psBlob->GetBufferPointer(), psBlob->GetBufferSize(), nullptr, &pPixelShader);
	if (FAILED(hr))
	{
		return -1;
	}

	return hr;

}

HRESULT create_depth_stencil(ID3D11Device* pd3dDevice, const D3D11_TEXTURE2D_DESC& backBufferDesc, ID3D11Texture2D*& pDepthStencilTex, ID3D11DepthStencilView*& pDepthStencilView)
{
	HRESULT hr = S_OK;

	// Create a depth-stencil view for use with 3D rendering if needed.
	CD3D11_TEXTURE2D_DESC depthStencilDesc(
		DXGI_FORMAT_D24_UNORM_S8_UINT,
		backBufferDesc.Width,
		backBufferDesc.Height,
		1, // This depth stencil view has only one texture.
		1, // Use a single mipmap level.
		D3D11_BIND_DEPTH_STENCIL);

	hr = pd3dDevice->CreateTexture2D(
		&depthStencilDesc,
		nullptr,
		&pDepthStencilTex);
	if (FAILED(hr))
	{
		return hr;
	}

	CD3D11_DEPTH_STENCIL_VIEW_DESC depthStencilViewDesc(D3D11_DSV_DIMENSION_TEXTURE2D);
	hr = pd3dDevice->CreateDepthStencilView(
		pDepthStencilTex,
		&depthStencilViewDesc,
		&pDepthStencilView);

	return hr;

}

HRESULT create_render_target(ID3D11Device* pd3dDevice, ID3D11Texture2D* pBackBuffer, ID3D11RenderTargetView*& pRenderTarget)
{
	HRESULT hr = pd3dDevice->CreateRenderTargetView(
		pBackBuffer,
		nullptr,
		&pRenderTarget);
	return hr;
}

HRESULT create_constant_buffer(ID3D11Device* pd3dDevice, ID3D11Buffer*& pConstantBuffer)
{
	HRESULT hr = S_OK;

	CD3D11_BUFFER_DESC cbDesc(
		sizeof(ConstantBufferStruct),
		D3D11_BIND_CONSTANT_BUFFER
	);

	hr = pd3dDevice->CreateBuffer(
		&cbDesc,
		nullptr,
		&pConstantBuffer);

	return hr;

}

HRESULT create_cube(ID3D11Device* pd3dDevice, ID3D11Buffer*& pVertexBuffer, ID3D11Buffer*& pIndexBuffer, int& indexCount)
{
	HRESULT hr = S_OK;

	// Create cube geometry.
	VertexPositionColor CubeVertices[] =
	{
		{DirectX::XMFLOAT3(-0.5f,-0.5f,-0.5f), DirectX::XMFLOAT2(0, 0),},
		{DirectX::XMFLOAT3(-0.5f,-0.5f, 0.5f), DirectX::XMFLOAT2(0, 1),},
		{DirectX::XMFLOAT3(-0.5f, 0.5f,-0.5f), DirectX::XMFLOAT2(1, 0),},
		{DirectX::XMFLOAT3(-0.5f, 0.5f, 0.5f), DirectX::XMFLOAT2(1, 1),},

		{DirectX::XMFLOAT3(0.5f,-0.5f,-0.5f), DirectX::XMFLOAT2(1, 1),},
		{DirectX::XMFLOAT3(0.5f,-0.5f, 0.5f), DirectX::XMFLOAT2(1, 0),},
		{DirectX::XMFLOAT3(0.5f, 0.5f,-0.5f), DirectX::XMFLOAT2(0, 1),},
		{DirectX::XMFLOAT3(0.5f, 0.5f, 0.5f), DirectX::XMFLOAT2(0, 0),},
	};

	// Create vertex buffer:

	CD3D11_BUFFER_DESC vDesc(
		sizeof(CubeVertices),
		D3D11_BIND_VERTEX_BUFFER);

	D3D11_SUBRESOURCE_DATA vData;
	ZeroMemory(&vData, sizeof(D3D11_SUBRESOURCE_DATA));
	vData.pSysMem = CubeVertices;
	vData.SysMemPitch = 0;
	vData.SysMemSlicePitch = 0;

	hr = pd3dDevice->CreateBuffer(
		&vDesc,
		&vData,
		&pVertexBuffer);

	// Create index buffer:
	unsigned short CubeIndices[] =
	{
		0,2,1, // -x
		1,2,3,

		4,5,6, // +x
		5,7,6,

		0,1,5, // -y
		0,5,4,

		2,6,7, // +y
		2,7,3,

		0,4,6, // -z
		0,6,2,

		1,3,7, // +z
		1,7,5,
	};

	indexCount = ARRAYSIZE(CubeIndices);

	CD3D11_BUFFER_DESC iDesc(
		sizeof(CubeIndices),
		D3D11_BIND_INDEX_BUFFER);

	D3D11_SUBRESOURCE_DATA iData;
	ZeroMemory(&iData, sizeof(D3D11_SUBRESOURCE_DATA));
	iData.pSysMem = CubeIndices;
	iData.SysMemPitch = 0;
	iData.SysMemSlicePitch = 0;

	hr = pd3dDevice->CreateBuffer(
		&iDesc,
		&iData,
		&pIndexBuffer);

	return hr;

}


void render(RenderDevice device, RenderContext rc, const ConstantBufferStruct& constantBufferData)
{
	// Use the Direct3D device context to draw.
	device.pDeviceContext->UpdateSubresource(
		rc.pVertexConstantBuffer,
		0,
		nullptr,
		&constantBufferData,
		0,
		0);

	// Clear the render target and the z-buffer.
	const float teal[] = { 0.0f, 0.0f, 0.0f, 1.000f };
	device.pDeviceContext->ClearRenderTargetView(
		device.pRenderTarget,
		teal);

	device.pDeviceContext->ClearDepthStencilView(
		device.pDepthStencilView,
		D3D11_CLEAR_DEPTH | D3D11_CLEAR_STENCIL,
		1.0f,
		0);

	// Set the render target.
	device.pDeviceContext->OMSetRenderTargets(
		1,
		&device.pRenderTarget,
		device.pDepthStencilView);

	// Set up the IA stage by setting the input topology and layout.
	UINT stride = sizeof(VertexPositionColor);
	UINT offset = 0;

	device.pDeviceContext->IASetVertexBuffers(
		0,
		1,
		&rc.pVertexBuffer,
		&stride,
		&offset);

	device.pDeviceContext->IASetIndexBuffer(
		rc.pIndexBuffer,
		DXGI_FORMAT_R16_UINT,
		0);

	device.pDeviceContext->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

	device.pDeviceContext->IASetInputLayout(rc.pInputLayout);

	// Set up the vertex shader stage.
	device.pDeviceContext->VSSetShader(rc.pVertexShader, nullptr, 0);

	// Set up the constant buffer
	device.pDeviceContext->VSSetConstantBuffers(0, 1, &rc.pVertexConstantBuffer);

	// Set up the pixel shader stage.
	device.pDeviceContext->PSSetShader(rc.pPixelShader, nullptr, 0);

	// Calling Draw tells Direct3D to start sending commands to the graphics device.
	device.pDeviceContext->DrawIndexed(rc.indexCount, 0, 0);

	// Present the frame to the screen.
	device.pSwapChain->Present(1, 0);

}

int frameCount = 45;

void setup_mvp_matrix(float aspectRatio, ConstantBufferStruct& constantBufferData)
{
	DirectX::XMVECTOR eye = DirectX::XMVectorSet(0.0f, 0.7f, 1.5f, 0.f);
	DirectX::XMVECTOR at = DirectX::XMVectorSet(0.0f, -0.1f, 0.0f, 0.f);
	DirectX::XMVECTOR up = DirectX::XMVectorSet(0.0f, 1.0f, 0.0f, 0.f);

	DirectX::XMFLOAT4X4 model;
	DirectX::XMFLOAT4X4 view;
	DirectX::XMFLOAT4X4 proj;

	DirectX::XMStoreFloat4x4(
		&model,
		DirectX::XMMatrixTranspose(
			DirectX::XMMatrixRotationAxis(
				DirectX::XMVectorSet(1.0f, 1.0f, 1.0f, 0.f),
				DirectX::XMConvertToRadians((float)frameCount++)
			)
		)
	);
	model.m[3][3] = 2.0f;

	DirectX::XMStoreFloat4x4(
		&view,
		DirectX::XMMatrixTranspose(
			DirectX::XMMatrixLookAtRH(
				eye,
				at,
				up
			)
		)
	);

	DirectX::XMStoreFloat4x4(
		&proj,
		DirectX::XMMatrixTranspose(
			DirectX::XMMatrixPerspectiveFovRH(
				DirectX::XMConvertToRadians(70),
				aspectRatio,
				0.01f,
				500.0f
			)
		)
	);

	DirectX::XMMATRIX mat_model = DirectX::XMLoadFloat4x4(&model);
	DirectX::XMMATRIX mat_view = DirectX::XMLoadFloat4x4(&view);
	DirectX::XMMATRIX mat_proj = DirectX::XMLoadFloat4x4(&proj);
	
	DirectX::XMMATRIX mat_vp = XMMatrixMultiply(mat_proj, mat_view);

	DirectX::XMStoreFloat4x4(&constantBufferData.m, mat_model);
	DirectX::XMStoreFloat4x4(&constantBufferData.vp, mat_vp);

}

void setup_mvp_matrix1(float aspectRatio, ConstantBufferStruct& constantBufferData)
{
	DirectX::XMVECTOR eye = DirectX::XMVectorSet(5.0f, 0.0f, 0.0f, 0.f);
	DirectX::XMVECTOR at = DirectX::XMVectorSet(0.0f, -0.1f, 0.0f, 0.f);
	DirectX::XMVECTOR up = DirectX::XMVectorSet(0.0f, 1.0f, 0.0f, 0.f);

	DirectX::XMFLOAT4X4 model;
	DirectX::XMFLOAT4X4 view;
	DirectX::XMFLOAT4X4 proj;

	DirectX::XMStoreFloat4x4(
		&model,
		DirectX::XMMatrixTranspose(
			DirectX::XMMatrixRotationAxis(
				DirectX::XMVectorSet(1.0f, 1.0f, 1.0f, 0.f),
				DirectX::XMConvertToRadians((float)frameCount++)
			)
		)
	);
	model.m[3][3] = 2.0f;

	DirectX::XMStoreFloat4x4(
		&view,
		DirectX::XMMatrixTranspose(
			DirectX::XMMatrixLookAtRH(
				eye,
				at,
				up
			)
		)
	);

	DirectX::XMStoreFloat4x4(
		&proj,
		DirectX::XMMatrixTranspose(
			DirectX::XMMatrixPerspectiveFovRH(
				DirectX::XMConvertToRadians(70),
				aspectRatio,
				0.01f,
				500.0f
			)
		)
	);

	DirectX::XMMATRIX mat_model = DirectX::XMLoadFloat4x4(&model);
	DirectX::XMMATRIX mat_view = DirectX::XMLoadFloat4x4(&view);
	DirectX::XMMATRIX mat_proj = DirectX::XMLoadFloat4x4(&proj);

	DirectX::XMMATRIX mat_vp = XMMatrixMultiply(mat_proj, mat_view);

	DirectX::XMStoreFloat4x4(&constantBufferData.m, mat_model);
	DirectX::XMStoreFloat4x4(&constantBufferData.vp, mat_vp);

}

void logic(float aspectRatio, ConstantBufferStruct& constantBufferData)
{
	setup_mvp_matrix(aspectRatio, constantBufferData);
}

void frame_loop(int cFrameRate, float aspectRatio, Timer& timer, RenderDevice device, RenderContext rc, ConstantBufferStruct& constantBufferData)
{
	float interv = 1000.0f / cFrameRate;
	float elapse_time = timer.GetElapseMilliseconds();
	if (elapse_time < interv)
	{
		render(device, rc, constantBufferData);
	}
	else
	{
		timer.Reset();
		logic(aspectRatio, constantBufferData);
		render(device, rc, constantBufferData);
	}
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

	// shader resource view
	ID3D11Texture2D* pCubeTexture = load_tex(pd3dDevice, "F:/work_astc/astc_cs/fruit.tga");
	
	D3D11_TEXTURE2D_DESC TexDesc;
	pCubeTexture->GetDesc(&TexDesc);

	ID3D11Buffer* pOutBuf = encode_astc(pSwapChain, pd3dDevice, pDeviceContext, pCubeTexture);


	ID3D11Texture2D* pDstTex = nullptr;

	D3D11_TEXTURE2D_DESC ASTC_Desc;
	ASTC_Desc.Width = xsize;		// grid size of the waves, rows
	ASTC_Desc.Height = ysize;		// grid size of the waves, colums
	ASTC_Desc.MipLevels = 1;
	ASTC_Desc.ArraySize = 1;
	ASTC_Desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
	ASTC_Desc.SampleDesc.Count = 1;
	ASTC_Desc.SampleDesc.Quality = 0;
	ASTC_Desc.Usage = D3D11_USAGE_DEFAULT;
	ASTC_Desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
	ASTC_Desc.CPUAccessFlags = 0;
	ASTC_Desc.MiscFlags = 0;

	D3D11_SUBRESOURCE_DATA ASTC_InitData;
	ASTC_InitData.pSysMem = new unsigned char[];
	ASTC_InitData.SysMemPitch = xsize * 4;
	ASTC_InitData.SysMemSlicePitch = xsize * ysize * 4;


	hr = pd3dDevice->CreateTexture2D(&TexDesc, &ASTC_InitData, &pDstTex);
	if (FAILED(hr))
	{
		return hr;
	}

	pDeviceContext->CopyResource(pDstTex, pOutBuf);

	// shader resource view
	D3D11_SHADER_RESOURCE_VIEW_DESC pTexViewDesc;
	pTexViewDesc.Format = TexDesc.Format;
	pTexViewDesc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
	pTexViewDesc.Texture2D.MipLevels = 1;
	pTexViewDesc.Texture2D.MostDetailedMip = 0;
	ID3D11ShaderResourceView* pCubeTextureRV = nullptr;
	hr = pd3dDevice->CreateShaderResourceView(pDstTex, &pTexViewDesc, &pCubeTextureRV);
	if (FAILED(hr))
	{
		return hr;
	}

	ID3D11Texture2D*        pBackBuffer = nullptr;
	ID3D11RenderTargetView* pRenderTarget = nullptr;

	// Configure the back buffer and viewport.
	hr = pSwapChain->GetBuffer(0, __uuidof(ID3D11Texture2D), (void**)&pBackBuffer);
	if (FAILED(hr))
	{
		return hr;
	}

	hr = create_render_target(pd3dDevice, pBackBuffer, pRenderTarget);
	if (FAILED(hr))
	{
		return hr;
	}

	D3D11_TEXTURE2D_DESC	backBufferDesc;
	pBackBuffer->GetDesc(&backBufferDesc);

	ID3D11Texture2D*		pDepthStencilTex = nullptr;
	ID3D11DepthStencilView* pDepthStencilView = nullptr;
	hr = create_depth_stencil(pd3dDevice, backBufferDesc, pDepthStencilTex, pDepthStencilView);
	if (FAILED(hr))
	{
		return hr;
	}

	D3D11_VIEWPORT          viewport;
	ZeroMemory(&viewport, sizeof(D3D11_VIEWPORT));
	viewport.Height = (float)cHeight;
	viewport.Width = (float)cWidth;
	viewport.MinDepth = 0;
	viewport.MaxDepth = 1;
	pDeviceContext->RSSetViewports(1, &viewport);


	D3D11_RASTERIZER_DESC rasterDesc;
	rasterDesc.AntialiasedLineEnable = false;
	rasterDesc.CullMode = D3D11_CULL_BACK;
	rasterDesc.DepthBias = 0;
	rasterDesc.DepthBiasClamp = 0.0f;
	rasterDesc.DepthClipEnable = true;
	rasterDesc.FillMode = D3D11_FILL_SOLID; // D3D11_FILL_SOLID D3D11_FILL_WIREFRAME
	rasterDesc.FrontCounterClockwise = false;
	rasterDesc.MultisampleEnable = false;
	rasterDesc.ScissorEnable = false;
	rasterDesc.SlopeScaledDepthBias = 0.0f;

	ID3D11RasterizerState*	 pRasterState = nullptr;
	hr = pd3dDevice->CreateRasterizerState(&rasterDesc, &pRasterState);
	if (FAILED(hr))
	{
		return hr;
	}
	pDeviceContext->RSSetState(pRasterState);


	ID3D11InputLayout*       pInputLayout = nullptr;
	ID3D11VertexShader*      pVertexShader = nullptr;
	ID3D11PixelShader*       pPixelShader = nullptr;
	ID3D11ComputeShader*     pComputeShader = nullptr;
	hr = create_cube_shader(pd3dDevice, pInputLayout, pVertexShader, pPixelShader);
	if (FAILED(hr))
	{
		return hr;
	}

	// buffer
	ID3D11Buffer*            pVertexConstantBuffer = nullptr;
	hr = create_constant_buffer(pd3dDevice, pVertexConstantBuffer);
	if (FAILED(hr))
	{
		return hr;
	}

	// cube object
	ID3D11Buffer*            pVertexBuffer = nullptr;
	ID3D11Buffer*            pIndexBuffer = nullptr;
	int indexCount = 0;
	hr = create_cube(pd3dDevice, pVertexBuffer, pIndexBuffer, indexCount);
	if (FAILED(hr))
	{
		return hr;
	}


	// Describe the Sample State
	D3D11_SAMPLER_DESC sampDesc;
	ZeroMemory(&sampDesc, sizeof(sampDesc));
	sampDesc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
	sampDesc.AddressU = D3D11_TEXTURE_ADDRESS_WRAP;
	sampDesc.AddressV = D3D11_TEXTURE_ADDRESS_WRAP;
	sampDesc.AddressW = D3D11_TEXTURE_ADDRESS_WRAP;
	sampDesc.ComparisonFunc = D3D11_COMPARISON_NEVER;
	sampDesc.MinLOD = 0;
	sampDesc.MaxLOD = D3D11_FLOAT32_MAX;

	//Create the Sample State
	ID3D11SamplerState* pCubeTextureSamplerState = nullptr;
	hr = pd3dDevice->CreateSamplerState(&sampDesc, &pCubeTextureSamplerState);
	if (FAILED(hr))
	{
		return hr;
	}

	pDeviceContext->PSSetShaderResources(0, 1, &pCubeTextureRV);
	pDeviceContext->PSSetSamplers(0, 1, &pCubeTextureSamplerState);

	// begin render
	RenderContext rc;
	rc.pVertexShader = pVertexShader;
	rc.pPixelShader = pPixelShader;
	rc.pVertexConstantBuffer = pVertexConstantBuffer;
	rc.pInputLayout = pInputLayout;
	rc.pVertexBuffer = pVertexBuffer;
	rc.pIndexBuffer = pIndexBuffer;
	rc.indexCount = indexCount;
	rc.pRasterState = pRasterState;

	ConstantBufferStruct constantBufferData;
	static_assert((sizeof(ConstantBufferStruct) % 16) == 0, "Constant Buffer size must be 16-byte aligned");
	setup_mvp_matrix(aspectRatio, constantBufferData);


	RenderDevice device;
	device.pd3dDevice = pd3dDevice;
	device.pSwapChain = pSwapChain;
	device.pDeviceContext = pDeviceContext;
	device.pRenderTarget = pRenderTarget;
	device.pDepthStencilView = pDepthStencilView;

	Timer timer;

	// Show the window
	::ShowWindow(hwnd, SW_SHOWDEFAULT);
	::UpdateWindow(hwnd);

	// Enter the message loop
	MSG msg;
	ZeroMemory(&msg, sizeof(msg));
	while (msg.message != WM_QUIT)
	{
		if (::PeekMessage(&msg, NULL, 0U, 0U, PM_REMOVE))
		{
			::TranslateMessage(&msg);
			::DispatchMessage(&msg);
		}
		else
		{
			frame_loop(cFrameRate, aspectRatio, timer, device, rc, constantBufferData);
		}
	}

	return 0;

}

