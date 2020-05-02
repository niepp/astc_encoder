#pragma once

#define _CRT_SECURE_NO_WARNINGS
#define _WIN32_WINNT 0x600
#include <stdio.h>

#include <d3d11.h>
#include <d3dcompiler.h>

typedef struct _csConstantBuffer
{
	int TexelWidth;
	int TexelHeight;
	int xGroupNum;
	int yGroupNum;
} CSConstantBuffer;


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


ID3D11Buffer* encode_astc(IDXGISwapChain *pSwapChain, ID3D11Device *pd3dDevice, ID3D11DeviceContext *pDeviceContext, ID3D11Texture2D *pCubeTexture)
{
	const int cFrameRate = 30;
	const int cWidth = 1280;
	const int cHeight = 800;

	const int cBlockDimX = 4;
	const int cBlockDimY = 4;
	const int cNumthreadX = 8; // same to compute shader [numthreads(8, 8, 1)]
	const int cNumthreadY = 8;

	float aspectRatio = 1.0f * cWidth / cHeight;

	// create shader
	ID3D11ComputeShader* computeShader = nullptr;
	HRESULT hr = create_shader(pd3dDevice, L"astc_encode.hlsl", "main", "cs_5_0", computeShader);
	if (FAILED(hr))
	{
		system("pause");
		return nullptr;
	}
	pDeviceContext->CSSetShader(computeShader, nullptr, 0);

	D3D11_TEXTURE2D_DESC TexDesc;
	pCubeTexture->GetDesc(&TexDesc);

	// shader resource view
	D3D11_SHADER_RESOURCE_VIEW_DESC pTexViewDesc;
	pTexViewDesc.Format = TexDesc.Format;
	pTexViewDesc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
	pTexViewDesc.Texture2D.MipLevels = 1;
	pTexViewDesc.Texture2D.MostDetailedMip = 0;
	ID3D11ShaderResourceView* pCubeTextureRV = nullptr;
	hr = pd3dDevice->CreateShaderResourceView(pCubeTexture, &pTexViewDesc, &pCubeTextureRV);
	if (FAILED(hr))
	{
		return nullptr;
	}

	pDeviceContext->CSSetShaderResources(0, 1, &pCubeTextureRV);

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
		return nullptr;
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
	if (FAILED(hr))
	{
		return nullptr;
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

	pDeviceContext->UpdateSubresource(pConstants, 0, 0, &ConstBuff, 0, 0);

	// 一个thread处理一个block
	pDeviceContext->Dispatch(xGroupNum, yGroupNum, 1);

	return pOutBuf;

}


