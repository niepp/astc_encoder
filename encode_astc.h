#pragma once

#define _CRT_SECURE_NO_WARNINGS
#define _WIN32_WINNT 0x600
#include <cmath>
#include <string>
#include <d3d11.h>
#include <d3dcompiler.h>

#define THREAD_NUM_X	8
#define THREAD_NUM_Y	8
#define BLOCK_BYTES		16
#define MAX_MIPS_NUM	14

struct encode_option
{
	bool is4x4;
	bool is_normal_map;
	bool fast;
	bool has_alpha;
	bool has_mips;
	encode_option() : is4x4(true)
		, is_normal_map(false)
		, fast(true)
		, has_alpha(false)
		, has_mips(false)
	{
	}
};


typedef struct _csConstantBuffer
{
	int TexelHeight;
	int TexelWidth;
	int MipsNum;
	int GroupNumX;
	int BlockNums[MAX_MIPS_NUM];
} CSConstantBuffer;


HRESULT compile_shader(_In_ LPCWSTR srcFile, _In_ LPCSTR entryPoint, LPCSTR target, const encode_option& option, _In_ ID3D11Device* device, _Outptr_ ID3DBlob** blob)
{
	if (!srcFile || !entryPoint || !device || !blob) {
		return E_INVALIDARG;
	}

	*blob = nullptr;

	UINT flags = D3DCOMPILE_ENABLE_STRICTNESS;
#if defined( DEBUG ) || defined( _DEBUG )
	flags |= D3DCOMPILE_DEBUG;
#endif

	auto cMAX_MIPS_NUM = std::to_string(MAX_MIPS_NUM);
	auto cTHREAD_NUM_X = std::to_string(THREAD_NUM_X);
	auto cTHREAD_NUM_Y = std::to_string(THREAD_NUM_Y);

	const D3D_SHADER_MACRO defines[] = {
		"MAX_MIPS_NUM", cMAX_MIPS_NUM.c_str(),
		"THREAD_NUM_X", cTHREAD_NUM_X.c_str(),
		"THREAD_NUM_Y", cTHREAD_NUM_Y.c_str(),
		"IS_NORMALMAP", option.is_normal_map ? "1" : "0",
		"FAST", option.fast ? "1" :"0",
		"BLOCK_6X6", option.is4x4 ? "0" : "1",
		"HAS_ALPHA", option.has_alpha ? "1" : "0",
		NULL, NULL
	};

	ID3DBlob* shaderBlob = nullptr;
	ID3DBlob* errorBlob = nullptr;
	HRESULT hr = D3DCompileFromFile(srcFile, defines, D3D_COMPILE_STANDARD_FILE_INCLUDE,
		entryPoint, target,
		flags, 0,
		&shaderBlob, &errorBlob);

	if (FAILED(hr)) {
		if (errorBlob) {
			printf((char*)errorBlob->GetBufferPointer());
			errorBlob->Release();
		}
		if (shaderBlob) {
			shaderBlob->Release();
		}
		return hr;
	}

	*blob = shaderBlob;

	return hr;
}

ID3D11Buffer* encode_astc(IDXGISwapChain *pSwapChain, ID3D11Device *pd3dDevice, ID3D11DeviceContext *pDeviceContext, ID3D11Texture2D *pSrcTexture, const encode_option& option, int MipsNum)
{
	// create shader
	// compile shader
	ID3DBlob * csBlob = nullptr;
	HRESULT hr = compile_shader(L"ASTC_Encode.hlsl", "MainCS", "cs_5_0", option, pd3dDevice, &csBlob);
	if (FAILED(hr)) {
		return nullptr;
	}

	// create compute shader
	ID3D11ComputeShader* computeShader = nullptr;
	hr = pd3dDevice->CreateComputeShader(csBlob->GetBufferPointer(), csBlob->GetBufferSize(), nullptr, &computeShader);
	if (FAILED(hr)) {
		return nullptr;
	}

	pDeviceContext->CSSetShader(computeShader, nullptr, 0);

	D3D11_TEXTURE2D_DESC TexDesc;
	pSrcTexture->GetDesc(&TexDesc);

	// shader resource view
	D3D11_SHADER_RESOURCE_VIEW_DESC pTexViewDesc;
	pTexViewDesc.Format = TexDesc.Format;
	pTexViewDesc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
	pTexViewDesc.Texture2D.MipLevels = 1;
	pTexViewDesc.Texture2D.MostDetailedMip = 0;
	ID3D11ShaderResourceView* pTextureSRV = nullptr;
	hr = pd3dDevice->CreateShaderResourceView(pSrcTexture, &pTexViewDesc, &pTextureSRV);
	if (FAILED(hr))	{
		return nullptr;
	}

	pDeviceContext->CSSetShaderResources(0, 1, &pTextureSRV);

	int DimSize = option.is4x4 ? 4 : 6;
	int TexWidth = TexDesc.Width;
	int TexHeight = TexDesc.Height;

	// flaten every mip to a one-dimension vector, then combination them together!
	int TotalBlockNum = 0;
	int BlockNums[MAX_MIPS_NUM] = {0};
	for (int MipLevel = 0; MipLevel < MipsNum; ++MipLevel)
	{
		int CurW = TexWidth >> MipLevel;
		int CurH = TexHeight >> MipLevel;
		int xBlockNum = (CurW + DimSize - 1) / DimSize;
		int yBlockNum = (CurH + DimSize - 1) / DimSize;
		TotalBlockNum += xBlockNum * yBlockNum;
		BlockNums[MipLevel + 1] = TotalBlockNum;
	}

	int GroupSize = THREAD_NUM_X * THREAD_NUM_Y;
	int GroupNum = (TotalBlockNum + GroupSize - 1) / GroupSize;
	int GroupNumX = (TexWidth + DimSize - 1) / DimSize;
	int GroupNumY = (GroupNum + GroupNumX - 1) / GroupNumX;

	// unordered access view for output astc buf
	D3D11_BUFFER_DESC sbOutDesc;
	sbOutDesc.BindFlags = D3D11_BIND_UNORDERED_ACCESS | D3D11_BIND_SHADER_RESOURCE;
	sbOutDesc.CPUAccessFlags = 0;
	sbOutDesc.Usage = D3D11_USAGE_DEFAULT;
	sbOutDesc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
	sbOutDesc.StructureByteStride = BLOCK_BYTES;
	sbOutDesc.ByteWidth = BLOCK_BYTES * TotalBlockNum;

	ID3D11Buffer* pOutBuf = nullptr;
	hr = pd3dDevice->CreateBuffer(&sbOutDesc, nullptr, &pOutBuf);
	if (FAILED(hr))	{
		return nullptr;
	}

	D3D11_UNORDERED_ACCESS_VIEW_DESC UAVDesc = {};
	UAVDesc.Buffer.FirstElement = 0;
	UAVDesc.Buffer.NumElements = sbOutDesc.ByteWidth / sbOutDesc.StructureByteStride;
	UAVDesc.Format = DXGI_FORMAT_UNKNOWN;
	UAVDesc.ViewDimension = D3D11_UAV_DIMENSION_BUFFER;

	ID3D11UnorderedAccessView* pOutUAV = nullptr;
	hr = pd3dDevice->CreateUnorderedAccessView(pOutBuf, &UAVDesc, &pOutUAV);
	if (FAILED(hr))	{
		return nullptr;
	}

	ID3D11UnorderedAccessView* pUAVs[] = { pOutUAV };
	pDeviceContext->CSSetUnorderedAccessViews(0, 1, pUAVs, 0);

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
	if (FAILED(hr)) {
		return nullptr;
	}
	pDeviceContext->CSSetConstantBuffers(0, 1, &pConstants);

	CSConstantBuffer ConstBuff;
	ConstBuff.TexelHeight = TexHeight;
	ConstBuff.TexelWidth = TexWidth;
	ConstBuff.MipsNum = MipsNum;
	ConstBuff.GroupNumX = GroupNumX;
	for (int i = 0; i < MAX_MIPS_NUM; ++i) {
		ConstBuff.BlockNums[i] = BlockNums[i];
	}

	pDeviceContext->UpdateSubresource(pConstants, 0, 0, &ConstBuff, 0, 0);

	// compress one block per thread
	pDeviceContext->Dispatch(GroupNumX, GroupNumY, 1);

	return pOutBuf;

}
