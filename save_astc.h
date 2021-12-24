#pragma once

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
	if (SUCCEEDED(pd3dDevice->CreateBuffer(&desc, nullptr, &pCpuBuf))) {
		pDeviceContext->CopyResource(pCpuBuf, pBuffer);
	}
	return pCpuBuf;
}

HRESULT read_gpu(ID3D11Device* pd3dDevice, ID3D11DeviceContext* pDeviceContext, ID3D11Buffer* pBuffer, uint8_t* pMemBuf, uint32_t buf_len)
{
	HRESULT hr = S_OK;
	ID3D11Buffer* pReadbackbuf = create_and_copyto_cpu_buf(pd3dDevice, pDeviceContext, pBuffer);
	if (!pReadbackbuf) {
		return E_OUTOFMEMORY;
	}

	D3D11_MAPPED_SUBRESOURCE mappedSrc;
	hr = pDeviceContext->Map(pReadbackbuf, 0, D3D11_MAP_READ, 0, &mappedSrc);
	if (FAILED(hr)) {
		return hr;
	}
	memcpy(pMemBuf, mappedSrc.pData, buf_len);
	pDeviceContext->Unmap(pReadbackbuf, 0);
	return S_OK;
}


void save_astc(const char* astc_path, int xdim, int ydim, int xsize, int ysize, uint8_t* buffer, int bufsz)
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

	FILE *wf = fopen(astc_path, "wb");
	fwrite(&hdr, 1, sizeof(astc_header), wf);
	fwrite(buffer, 1, bufsz, wf);
	fclose(wf);
}

