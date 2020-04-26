#define WIDTH 1280
#define HEIGHT 800

#define _CRT_SECURE_NO_WARNINGS
#define _WIN32_WINNT 0x600
#include <stdio.h>

#include <d3d11.h>
#include <d3dcompiler.h>
#include "DDSTextureLoader.h"

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "d3dcompiler.lib")
#pragma comment(lib, "dxguid.lib") 

#define MAGIC_FILE_CONSTANT 0x5CA1AB13

struct astc_header
{
	uint8_t magic[4];
	uint8_t blockdim_x;
	uint8_t blockdim_y;
	uint8_t blockdim_z;
	uint8_t xsize[3];			// x-size = xsize[0] + xsize[1] + xsize[2]
	uint8_t ysize[3];			// x-size, y-size and z-size are given in texels;
	uint8_t zsize[3];			// block count is inferred
};


typedef struct _csConstantBuffer
{
	int TexelWidth;
	int TexelHeight;
	int xGroupNum;
	int yGroupNum;
} CSConstantBuffer;

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
	desc.BufferUsage = DXGI_USAGE_UNORDERED_ACCESS; // DXGI_USAGE_RENDER_TARGET_OUTPUT		DXGI_USAGE_UNORDERED_ACCESS;
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


HRESULT compile_shader(_In_ LPCWSTR srcFile, _In_ LPCSTR entryPoint, LPCSTR target, _In_ ID3D11Device* device, _Outptr_ ID3DBlob** blob)
{
	if (!srcFile || !entryPoint || !device || !blob)
		return E_INVALIDARG;

	*blob = nullptr;

	UINT flags = D3DCOMPILE_ENABLE_STRICTNESS;
#if defined( DEBUG ) || defined( _DEBUG )
	flags |= D3DCOMPILE_DEBUG;
#endif

	const D3D_SHADER_MACRO defines[] =
	{
		"EXAMPLE_DEFINE", "1",
		NULL, NULL
	};

	ID3DBlob* shaderBlob = nullptr;
	ID3DBlob* errorBlob = nullptr;
	HRESULT hr = D3DCompileFromFile(srcFile, defines, D3D_COMPILE_STANDARD_FILE_INCLUDE,
		entryPoint, target,
		flags, 0,
		&shaderBlob, &errorBlob);

	if (FAILED(hr))
	{
		if (errorBlob)
		{
			printf((char*)errorBlob->GetBufferPointer());
			errorBlob->Release();
		}

		if (shaderBlob)
			shaderBlob->Release();

		return hr;
	}

	*blob = shaderBlob;

	return hr;
}


HRESULT create_shader(ID3D11Device* pd3dDevice, LPCWSTR srcFile, LPCSTR entryPoint, LPCSTR target, ID3D11ComputeShader*& pComputeShader)
{
	HRESULT hr = S_OK;

	// Compile shader
	ID3DBlob *csBlob = nullptr;
	hr = compile_shader(srcFile, entryPoint, target, pd3dDevice, &csBlob);
	if (FAILED(hr))
	{
		return -1;
	}

	// Create compute shader
	hr = pd3dDevice->CreateComputeShader(csBlob->GetBufferPointer(), csBlob->GetBufferSize(), nullptr, &pComputeShader);
	if (FAILED(hr))
	{
		return -1;
	}

	return hr;

}


HRESULT create_shader_resource_view(ID3D11Device* pd3dDevice, const wchar_t* texName, ID3D11Texture2D*& pCubeTexture, ID3D11ShaderResourceView*& pCubeTextureRV)
{
	HRESULT hr = S_OK;

	// create texture
	hr = DirectX::CreateDDSTextureFromFile(pd3dDevice, texName, (ID3D11Resource**)&pCubeTexture, &pCubeTextureRV);
	return hr;
}

//--------------------------------------------------------------------------------------
// Create a CPU accessible buffer and download the content of a GPU buffer into it
//-------------------------------------------------------------------------------------- 
ID3D11Buffer* create_and_copyto_cpu_buf(ID3D11Device* pd3dDevice, ID3D11DeviceContext* pDeviceContext, ID3D11Buffer* pBuffer)
{
	ID3D11Buffer* pCpuBuf = nullptr;
	D3D11_BUFFER_DESC desc = {};
	pBuffer->GetDesc(&desc);
	desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
	desc.Usage = D3D11_USAGE_STAGING;
	desc.BindFlags = 0;
	desc.MiscFlags = 0;
	if (SUCCEEDED(pd3dDevice->CreateBuffer(&desc, nullptr, &pCpuBuf)))
	{
		pDeviceContext->CopyResource(pCpuBuf, pBuffer);
	}
	return pCpuBuf;
}

HRESULT read_gpu(ID3D11Device* pd3dDevice, ID3D11DeviceContext* pDeviceContext, ID3D11Buffer* pBuffer, uint8_t* pMemBuf, uint32_t buf_len)
{
	HRESULT hr = S_OK;
	ID3D11Buffer* pReadbackbuf = create_and_copyto_cpu_buf(pd3dDevice, pDeviceContext, pBuffer);
	if (!pReadbackbuf)
	{
		return E_OUTOFMEMORY;
	}

	D3D11_MAPPED_SUBRESOURCE mappedSrc;
	hr = pDeviceContext->Map(pReadbackbuf, 0, D3D11_MAP_READ, 0, &mappedSrc);
	if (FAILED(hr))
	{
		return hr;
	}
	memcpy(pMemBuf, mappedSrc.pData, buf_len);
	pDeviceContext->Unmap(pReadbackbuf, 0);
	return S_OK;
}


void save_astc(const char* astc_path, int xdim, int ydim, int xsize, int ysize, uint8_t* buffer)
{
	astc_header hdr;
	hdr.magic[0] = MAGIC_FILE_CONSTANT & 0xFF;
	hdr.magic[1] = (MAGIC_FILE_CONSTANT >> 8) & 0xFF;
	hdr.magic[2] = (MAGIC_FILE_CONSTANT >> 16) & 0xFF;
	hdr.magic[3] = (MAGIC_FILE_CONSTANT >> 24) & 0xFF;
	hdr.blockdim_x = xdim;
	hdr.blockdim_y = ydim;
	hdr.blockdim_z = 1;
	hdr.xsize[0] = xsize & 0xFF;
	hdr.xsize[1] = (xsize >> 8) & 0xFF;
	hdr.xsize[2] = (xsize >> 16) & 0xFF;
	hdr.ysize[0] = ysize & 0xFF;
	hdr.ysize[1] = (ysize >> 8) & 0xFF;
	hdr.ysize[2] = (ysize >> 16) & 0xFF;
	hdr.zsize[0] = 1;
	hdr.zsize[1] = 0;
	hdr.zsize[2] = 0;

	int xblocks = (xsize + xdim - 1) / xdim;
	int yblocks = (ysize + ydim - 1) / ydim;

	FILE *wf = fopen(astc_path, "wb");
	fwrite(&hdr, 1, sizeof(astc_header), wf);
	fwrite(buffer, 1, xblocks * yblocks * 16, wf);
	fclose(wf);
	free(buffer);
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

	// create shader
	ID3D11ComputeShader* computeShader = nullptr;
	hr = create_shader(pd3dDevice, L"astc_encode.hlsl", "main", "cs_5_0", computeShader);
	if (FAILED(hr))
	{
		system("pause");
		return hr;
	}
	pDeviceContext->CSSetShader(computeShader, nullptr, 0);

	// shader resource view
	ID3D11Texture2D* pCubeTexture = nullptr;
	ID3D11ShaderResourceView* pCubeTextureRV = nullptr;
	hr = create_shader_resource_view(pd3dDevice, L"F:/work_astc/astc_cs/fruit.dds", pCubeTexture, pCubeTextureRV);
	if (FAILED(hr))
	{
		return hr;
	}
	pDeviceContext->CSSetShaderResources(0, 1, &pCubeTextureRV);

	D3D11_TEXTURE2D_DESC TexDesc;
	pCubeTexture->GetDesc(&TexDesc);

	// unordered access view on back buffer
	ID3D11Texture2D*        pBackBuffer = nullptr;
	ID3D11UnorderedAccessView* pTexUAV = nullptr;
	hr = pSwapChain->GetBuffer(0, __uuidof(ID3D11Texture2D), (LPVOID*)&pBackBuffer);
	if (FAILED(hr))
	{
		return hr;
	}

	D3D11_TEXTURE2D_DESC backBufferDesc;
	pBackBuffer->GetDesc(&backBufferDesc);

	hr = pd3dDevice->CreateUnorderedAccessView((ID3D11Texture2D*)pBackBuffer, nullptr, (ID3D11UnorderedAccessView**)&pTexUAV);
	if (FAILED(hr))
	{
		return hr;
	}

	// unordered access view for output astc buf
	D3D11_BUFFER_DESC sbOutDesc;
	sbOutDesc.BindFlags = D3D11_BIND_UNORDERED_ACCESS | D3D11_BIND_SHADER_RESOURCE;
	sbOutDesc.CPUAccessFlags = 0;
	sbOutDesc.Usage = D3D11_USAGE_DEFAULT;
	sbOutDesc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
	sbOutDesc.StructureByteStride = 16;
	sbOutDesc.ByteWidth = 16 * ((TexDesc.Height + cBlockDimY - 1) / cBlockDimY) * ((TexDesc.Width + cBlockDimX - 1) / cBlockDimX);

	ID3D11Buffer* pOutBuf = nullptr;
	hr = pd3dDevice->CreateBuffer(&sbOutDesc, nullptr, &pOutBuf);
	if (FAILED(hr))
	{
		return hr;
	}

	D3D11_UNORDERED_ACCESS_VIEW_DESC UAVDesc = {};
	UAVDesc.Buffer.FirstElement = 0;
	UAVDesc.Buffer.NumElements = sbOutDesc.ByteWidth / sbOutDesc.StructureByteStride;
	UAVDesc.Format = DXGI_FORMAT_UNKNOWN;
	UAVDesc.ViewDimension = D3D11_UAV_DIMENSION_BUFFER;

	ID3D11UnorderedAccessView* pOutUAV = nullptr;
	hr = pd3dDevice->CreateUnorderedAccessView(pOutBuf, &UAVDesc, &pOutUAV);
	if (FAILED(hr))
	{
		return hr;
	}

	ID3D11UnorderedAccessView* pUAVs[] = { pTexUAV, pOutUAV };
	pDeviceContext->CSSetUnorderedAccessViews(0, 2, pUAVs, 0);

	D3D11_BUFFER_DESC ConstBufferDesc;
	ConstBufferDesc.ByteWidth = 16;
	ConstBufferDesc.Usage = D3D11_USAGE_DEFAULT;
	ConstBufferDesc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
	ConstBufferDesc.CPUAccessFlags = 0;
	ConstBufferDesc.MiscFlags = 0;
	ConstBufferDesc.StructureByteStride = 0;

	// constant buffer
	ID3D11Buffer *pConstants;
	hr = pd3dDevice->CreateBuffer(&ConstBufferDesc, nullptr, &pConstants);
	if (FAILED(hr))
	{
		return hr;
	}
	pDeviceContext->CSSetConstantBuffers(0, 1, &pConstants);

	int xGroupSize = cBlockDimX * cNumthreadX;
	int yGroupSize = cBlockDimY * cNumthreadY;
	int xGroupNum = (TexDesc.Width + xGroupSize - 1) / xGroupSize;
	int yGroupNum = (TexDesc.Height+ yGroupSize - 1) / yGroupSize;

	CSConstantBuffer ConstBuff;
	ConstBuff.TexelWidth = TexDesc.Width;
	ConstBuff.TexelHeight = TexDesc.Height;
	ConstBuff.xGroupNum = xGroupNum;
	ConstBuff.yGroupNum = yGroupNum;


	//MSG msg;
	//ZeroMemory(&msg, sizeof(msg));
	//while (msg.message != WM_QUIT)
	//{
	//	if (::PeekMessage(&msg, NULL, 0U, 0U, PM_REMOVE))
	//	{
	//		::TranslateMessage(&msg);
	//		::DispatchMessage(&msg);
	//	}
	//	else
	//	{
	//		pDeviceContext->UpdateSubresource(pConstants, 0, 0, &ConstBuff, 0, 0);

	//		// 一个thread处理一个block
	//		pDeviceContext->Dispatch(xGroupNum, yGroupNum, 1);

	//		pSwapChain->Present(0, 0);

	//	}
	//}

	pDeviceContext->UpdateSubresource(pConstants, 0, 0, &ConstBuff, 0, 0);

	// 一个thread处理一个block
	pDeviceContext->Dispatch(xGroupNum, yGroupNum, 1);

	pSwapChain->Present(0, 0);

	////
	//D3D11_SHADER_RESOURCE_VIEW_DESC pDesc;
	//ID3D11ShaderResourceView* pSRView = nullptr;
	//pCubeTextureRV->GetDesc(&pDesc);
	//hr = pd3dDevice->CreateShaderResourceView(pOutBuf, &pDesc, &pSRView);
	//if (FAILED(hr))
	//{
	//	return hr;
	//}

	uint32_t bufLen = sbOutDesc.ByteWidth;
	uint8_t* pMemBuf = new uint8_t[bufLen];
	ZeroMemory(pMemBuf, bufLen);
	read_gpu(pd3dDevice, pDeviceContext, pOutBuf, pMemBuf, sbOutDesc.ByteWidth);

	save_astc("F:/work_astc/ASTC_preview/Assets/Resources/fruit_cs.astc", cBlockDimX, cBlockDimX, TexDesc.Width, TexDesc.Height, pMemBuf);

	return 0;

}

