#define _CRT_SECURE_NO_WARNINGS
#define _WIN32_WINNT 0x600

#include <string>
#include <iostream>

#include <d3d11.h>
#include <d3dcompiler.h>
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "d3dcompiler.lib")

#define STB_IMAGE_IMPLEMENTATION

#include "stb_image.h"

#include "astc_encode.h"
#include "astc_save.h"

ID3D11Texture2D* load_tex(ID3D11Device* pd3dDevice, const char* tex_path, bool bSRGB)
{
	int xsize = 0;
	int ysize = 0;
	int components = 0;
	stbi_set_flip_vertically_on_load(1);
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
		if (index < argc && *(argv[index]) == '-') {
			ret = true;
			return true;
		}
		return false;
	};

	for (int i = 2; i < argc; ++i) {
		if (argv[i] == std::string("-4x4")) {
			if (!func_arg_value(i, argc, argv, option.is4x4)) {
				return false;
			}
		}
		else if (argv[i] == std::string("-6x6")) {
			if (!func_arg_value(i, argc, argv, option.is6x6)) {
				return false;
			}
		}
		else if (argv[i] == std::string("-norm")) {
			if (!func_arg_value(i, argc, argv, option.is_normal_map)) {
				return false;
			}
		}
		else if (argv[i] == std::string("-srgb")) {
			if (!func_arg_value(i, argc, argv, option.srgb)) {
				return false;
			}
		}
		else if (argv[i] == std::string("-alpha")) {
			if (!func_arg_value(i, argc, argv, option.has_alpha)) {
				return false;
			}
		}
	}
	return true;
}

int main(int argc, char** argv)
{
	if (argc < 2) {
		std::cout << "wrong args count" << std::endl;
		return -1;
	}

	encode_option option;
	if (!parse_cmd(argc, argv, option)) {
		std::cout << "wrong args options" << std::endl;
		return -1;
	}

	std::cout << "encode option setting:\n"
		<< "has_alpha\t" << std::boolalpha << option.has_alpha << std::endl
		<< "is 4x4 block\t" << option.is4x4 << std::endl
		<< "normal map\t" << option.is_normal_map << std::endl
		<< "encode in gamma color space\t" << option.srgb << std::endl;

	HWND hwnd = ::GetDesktopWindow();

	// setting up device
	IDXGISwapChain* pSwapChain = nullptr;
	ID3D11Device* pd3dDevice = nullptr;
	ID3D11DeviceContext* pDeviceContext = nullptr;
	HRESULT hr = create_device_swapchain(hwnd, pSwapChain, pd3dDevice, pDeviceContext);
	if (FAILED(hr))	{
		std::cout << "init d3d failed!" << std::endl;
		return hr;
	}

	std::string src_tex = argv[1];

	// shader resource view
	ID3D11Texture2D* pSrcTexture = load_tex(pd3dDevice, src_tex.c_str(), option.srgb && (!option.is_normal_map));
	if (pSrcTexture == nullptr) {
		std::cout << "load source texture failed! [" << src_tex << "]" << std::endl;
		return -1;
	}

	D3D11_TEXTURE2D_DESC TexDesc;
	pSrcTexture->GetDesc(&TexDesc);
	int TexWidth = TexDesc.Width;
	int TexHeight = TexDesc.Height;

	ID3D11Buffer* pOutBuf = encode_astc(pd3dDevice, pDeviceContext, pSrcTexture, option);
	if (pOutBuf == nullptr) {
		std::cout << "encode astc failed!" << std::endl;
		return -1;
	}

	// save to file
	D3D11_BUFFER_DESC sbDesc;
	pOutBuf->GetDesc(&sbDesc);

	uint32_t bufLen = sbDesc.ByteWidth;
	uint8_t* pMemBuf = new uint8_t[bufLen];
	ZeroMemory(pMemBuf, bufLen);
	hr = read_gpu(pd3dDevice, pDeviceContext, pOutBuf, pMemBuf, bufLen);
	if (FAILED(hr)) {
		std::cout << "save astc failed!" << std::endl;
		return -1;
	}

	std::string dst_tex(src_tex);
	strip_file_extension(dst_tex);
	dst_tex += ".astc";

	int DimSize = option.is4x4 ? 4 : 6;
	save_astc(dst_tex.c_str(), DimSize, DimSize, TexDesc.Width, TexDesc.Height, pMemBuf, bufLen);

	delete[] pMemBuf;
	pMemBuf = nullptr;

	std::cout << "save astc to:" << dst_tex << std::endl;

	return 0;

}

