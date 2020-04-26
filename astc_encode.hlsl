
#define RootSig \
    "RootFlags(0), " \
    "RootConstants(b0, num32BitConstants = 4), " \
    "DescriptorTable(SRV(t0, numDescriptors = 1))," \
    "DescriptorTable(UAV(u0, numDescriptors = 2))"

cbuffer TexInfo : register(b0)
{
	int TexelWidth;
	int TexelHeight;
	int xGroupNum;
	int yGroupNum;
}

Texture2D g_SrcTex 			: register(t0);
RWTexture2D<float4> g_DstTex  		: register(u0);
RWStructuredBuffer<uint4> g_DstBuf  : register(u1);

#define THREAD_NUM_X 8
#define THREAD_NUM_Y 8

#include "astc_define.hlsl"
#include "astc_table.hlsl"
#include "astc_weights_quantize.hlsl"
#include "astc_integer_sequence_encoding.hlsl"


float3 mean(uint4 texels[BLOCK_SIZE], uint count)
{
	float3 sum = float3(0, 0, 0);
	for (uint i = 0; i < count; ++i)
	{
		sum += texels[i].xyz;
	}
	return sum / count;
}

void subtract(uint4 texels[BLOCK_SIZE], uint count, float3 avg, out float3 output[BLOCK_SIZE])
{
	for (uint i = 0; i < count; ++i)
	{
		output[i] = texels[i].xyz - avg;
	}
}

float3x3 covariance(float3 m[BLOCK_SIZE], uint count)
{
	float3x3 cov;
	for (uint i = 0; i < 3; ++i)
	{
		for (uint j = 0; j < 3; ++j)
		{
			float s = 0;
			for (uint k = 0; k < count; ++k)
			{
				s += m[k][i] * m[k][j];
			}
			cov[i][j] = s / (count - 1);
		}
	}
	return cov;
}


float3 eigen_vector(float3x3 m)
{
	// 迭代计算特征向量
	float3 v = normalize(float3(1, 3, 2));  // FIXME: Magic number
	for (uint i = 0; i < 8; ++i)
	{
		v = normalize(mul(m, v));
	}
	return v;
}

void principal_component_analysis(uint4 texels[BLOCK_SIZE], uint count,	out float3 line_k, out float3 line_m)
{
	line_m = mean(texels, count);

	float3 n[BLOCK_SIZE];
	subtract(texels, count, line_m, n);

	float3x3 m = covariance(n, count);

	line_k = eigen_vector(m);

}

void find_min_max(uint4 texels[BLOCK_SIZE], uint count, float3 line_k, float3 line_m, out float3 e0, out float3 e1)
{
	float a = 1e31;
	float b = -1e31;
	for (uint i = 0; i < count; ++i)
	{
		float3 pix = float3(texels[i].r, texels[i].g, texels[i].b);
		float t = dot(pix - line_m, line_k);
		a = min(a, t);
		b = max(b, t);
	}
	e0 = clamp(line_k * a + line_m, 0, 255);
	e1 = clamp(line_k * b + line_m, 0, 255);
}


void compute_dominant_direction_pca(uint4 texels[BLOCK_SIZE], uint count, out float3 e0, out float3 e1)
{
	float3 line_k, line_m;
	principal_component_analysis(texels, count, line_k, line_m);
	find_min_max(texels, count, line_k, line_m, e0, e1);
}


// return 0 on invalid mode, 1 on valid mode.
uint decode_block_mode_2d(uint blockmode, uint xdim, uint ydim, out uint Nval, out uint Mval, out uint dual_weight_plane, out uint quant_mode)
{
	Nval = 0; Mval = 0, dual_weight_plane = 0, quant_mode = 0;

	uint base_quant_mode = (blockmode >> 4) & 1;
	uint H = (blockmode >> 9) & 1;
	uint D = (blockmode >> 10) & 1;

	uint A = (blockmode >> 5) & 0x3;

	uint N = 0, M = 0;

	if ((blockmode & 3) != 0)
	{
		base_quant_mode |= (blockmode & 3) << 1;
		uint B = (blockmode >> 7) & 3;
		switch ((blockmode >> 2) & 3)
		{
		case 0:
			N = B + 4;
			M = A + 2;
			break;
		case 1:
			N = B + 8;
			M = A + 2;
			break;
		case 2:
			N = A + 2;
			M = B + 8;
			break;
		case 3:
			B &= 1;
			if (blockmode & 0x100)
			{
				N = B + 2;
				M = A + 2;
			}
			else
			{
				N = A + 2;
				M = B + 6;
			}
			break;
		}
	}
	else
	{
		base_quant_mode |= ((blockmode >> 2) & 3) << 1;
		if (((blockmode >> 2) & 3) == 0)
			return 0;
		uint B = (blockmode >> 9) & 3;
		switch ((blockmode >> 7) & 3)
		{
		case 0:
			N = 12;
			M = A + 2;
			break;
		case 1:
			N = A + 2;
			M = 12;
			break;
		case 2:
			N = A + 6;
			M = B + 6;
			D = 0;
			H = 0;
			break;
		case 3:
			switch ((blockmode >> 5) & 3)
			{
			case 0:
				N = 6;
				M = 10;
				break;
			case 1:
				N = 10;
				M = 6;
				break;
			case 2:
			case 3:
				return 0;
			}
			break;
		}
	}

	uint weight_count = N * M * (D + 1);
	uint qmode = (base_quant_mode - 2) + 6 * H;

	uint weightbits = compute_ise_bitcount(weight_count, qmode);
	if (weight_count > MAX_WEIGHTS_PER_BLOCK
		|| weightbits < MIN_WEIGHT_BITS_PER_BLOCK
		|| weightbits > MAX_WEIGHT_BITS_PER_BLOCK)
	{
		return 0;
	}

	if (N > xdim || M > ydim)
	{
		return 0;
	}

	Nval = N;
	Mval = M;
	dual_weight_plane = D;
	quant_mode = qmode;
	return 1;
}


uint encode_block_mode(uint xdim, uint ydim, out uint x_grids, out uint y_grids, out uint quantize_mode)
{
	// then construct the list of block formats
	for (uint i = 0; i < BLOCK_MODE_COUNT; ++i)
	{
		uint is_dual_plane = 0;
		if (decode_block_mode_2d(i, xdim, ydim, x_grids, y_grids, is_dual_plane, quantize_mode))
		{
			return i;
		}
	}
	return 0;
}


uint quantize_color(uint quant, uint c)
{
	//astc_assert(c >= 0 && c <= 255);
	return color_quantize_table[quant][c];
}

uint3 quantize_color(uint quant, uint3 c)
{
	uint3 result;
	result.r = color_quantize_table[quant][c.r];
	result.g = color_quantize_table[quant][c.g];
	result.b = color_quantize_table[quant][c.b];
	return result;
}

uint unquantize_color(uint quant, uint c)
{
	//astc_assert(c >= 0 && c <= 255);
	return color_unquantize_table[quant][c];
}

uint3 unquantize_color(uint quant, uint3 c)
{
	uint3 result;
	result.r = color_unquantize_table[quant][c.r];
	result.g = color_unquantize_table[quant][c.g];
	result.b = color_unquantize_table[quant][c.b];
	return result;
}


void encode_rgb_direct(uint endpoints_quantmethod,	uint3 e0, uint3 e1, out uint endpoint_quantized[6])
{
	uint3 e0q = quantize_color(endpoints_quantmethod, e0);
	uint3 e1q = quantize_color(endpoints_quantmethod, e1);

	uint3 e0u = unquantize_color(endpoints_quantmethod, e0q);
	uint3 e1u = unquantize_color(endpoints_quantmethod, e1q);

	// ASTC uses a different blue contraction encoding when the sum of values for
	// the first endpoint is larger than the sum of values in the second
	// endpoint. Sort the endpoints to ensure that the normal encoding is used.
	if (color_channel_sum(e0u) > color_channel_sum(e1u))
	{
		swap(e0q, e1q);
	}

	endpoint_quantized[0] = e0q.r;
	endpoint_quantized[1] = e1q.r;
	endpoint_quantized[2] = e0q.g;
	endpoint_quantized[3] = e1q.g;
	endpoint_quantized[4] = e0q.b;
	endpoint_quantized[5] = e1q.b;

}


uint4 symbolic_to_physical(
	uint color_endpoint_mode,
	uint endpoint_quantmethod,
	uint weight_quantmethod,
	uint partition_count,
	uint partition_index,
	in uint4 endpoint_ise,
	in uint4 weights_ise)
{
	uint n = BLOCK_SIZE_X;
	uint m = BLOCK_SIZE_Y;

	// more details from "Table C.2.7 - Weight Range Encodings"
	static const uint h_table[MAX_WEIGHT_RANGE_NUM] = { 0, 0, 0, 0, 0, 0,
														1, 1, 1, 1, 1, 1 };

	static const uint r_table[MAX_WEIGHT_RANGE_NUM] = { 0x2, 0x3, 0x4, 0x5, 0x6, 0x7,
														0x2, 0x3, 0x4, 0x5, 0x6, 0x7 };

	uint h = h_table[weight_quantmethod];
	uint r = r_table[weight_quantmethod];

	// Use the first row of Table 11 in the ASTC specification. Beware that
	// this has to be changed if another block-size is used.
	uint a = m - 2;
	uint b = n - 4;

	a = min(a, 3);
	b = min(b, 3);

	bool d = 0;  // TODO: dual plane

	bool multi_part = partition_count > 1;

	uint part_value = partition_count - 1;
	uint part_index = multi_part ? partition_index : 0;

	uint cem_offset = multi_part ? 23 : 13;
	uint ced_offset = multi_part ? 29 : 17;

	uint cem_bits = multi_part ? 6 : 4;
	uint cem = color_endpoint_mode;
	// astc_assert(cem < (multi_part ? CEM_MULTI_MAX : CEM_MAX));

	uint i = 0;
	uint4 phy_blk = 0;

	uint weights[16];
	uint4_2_array16(weights_ise, weights);

	i = 0;
	uint j = MAX_ENCODED_WEIGHT_BYTES - 1;
	for (; i < j; ++i, --j)
	{
		swap(weights[i], weights[j]);
	}

	for (i = 0; i < MAX_ENCODED_WEIGHT_BYTES; ++i)
	{
		weights[i] = reverse_byte(weights[i]);
	}

	for (i = BLOCK_BYTES - 1; i >= BLOCK_BYTES - MAX_ENCODED_WEIGHT_BYTES; --i)
	{
		weights[i] = weights[i - (BLOCK_BYTES - MAX_ENCODED_WEIGHT_BYTES)];
	}

	phy_blk = array16_2_uint4(weights);

	// Block mode
	uint blockmode = 0;
	blockmode |= getbit(r, 1);
	blockmode |= getbit(r, 2) << 1;
	blockmode |= 0 << 2;
	blockmode |= 0 << 3;

	blockmode |= getbit(r, 0) << 4;
	blockmode |= a << 5;
	blockmode |= b << 7;
	blockmode |= h << 9;
	blockmode |= d << 10;

	blockmode |= part_value << 11;  // partitions

	uint bitpos = 13;

	phy_blk = orbits8_ptr(phy_blk, 0, blockmode, 8);
	phy_blk = orbits8_ptr(phy_blk, 8, blockmode >> 8, 5);


	//if (multi_part)
	//{
	//	orbits16_ptr(phy_blk, 13, part_index, 10);
	//}

	// CEM
	phy_blk = orbits8_ptr(phy_blk, cem_offset, cem, cem_bits);

	copy_bytes(endpoint_ise, MAX_ENCODED_COLOR_ENDPOINT_BYTES, phy_blk, ced_offset);

	return phy_blk;

}

uint4 encode_rgb_single_partition(uint4 texels[BLOCK_SIZE], float3 e0, float3 e1)
{
	// todo
	uint partition_index = 0;
	uint partition_count = 1;

	// todo
	uint color_endpoint_mode = CEM_LDR_RGB_DIRECT;

	uint x_grids = 0;
	uint y_grids = 0;
	uint weight_quantmethod;

	uint block_mode = encode_block_mode(BLOCK_SIZE_X, BLOCK_SIZE_Y, x_grids, y_grids, weight_quantmethod);

	// weight_quantmethod = 5;

	// todo
	x_grids = BLOCK_SIZE_X;
	y_grids = BLOCK_SIZE_Y;

	uint weights_count = x_grids * y_grids;
	uint endpoints_quantmethod = QUANT_256;
	
	uint i = 0;

	// endpoints量化
	uint endpoint_quantized[6];
	int3 ie0 = round(e0);
	int3 ie1 = round(e1);
	encode_rgb_direct(endpoints_quantmethod, ie0, ie1, endpoint_quantized);	

	// 插值权重量化
	uint weights_quantized[BLOCK_SIZE];
	calculate_quantized_weights_rgb(texels, weight_quantmethod, ie0, ie1, weights_quantized, x_grids, y_grids);

	uint4 endpoint_ise = 0;	
	// ise encode endpoints
	uint src_buf[ISE_BYTE_COUNT];
	for (i = 0; i < ISE_BYTE_COUNT; ++i)
	{
		src_buf[i] = 0;
	}
	for (i = 0; i < 6; ++i)
	{
		src_buf[i] = endpoint_quantized[i];
	}

	uint dst_count = ISE_BYTE_COUNT;
	integer_sequence_encode(src_buf, 6, endpoints_quantmethod, endpoint_ise, dst_count);

	// ise encode weights
	dst_count = 0;
	uint4 weights_ise = 0;
	for (i = 0; i < ISE_BYTE_COUNT; ++i)
	{
		src_buf[i] = i < weights_count ? weights_quantized[i] : 0;
	}
	integer_sequence_encode(src_buf, weights_count, weight_quantmethod, weights_ise, dst_count);

	return symbolic_to_physical(color_endpoint_mode, endpoints_quantmethod, weight_quantmethod, partition_count, partition_index, endpoint_ise, weights_ise);

}

uint4 compress(uint4 texels[BLOCK_SIZE])
{
	float3 e0, e1;
	compute_dominant_direction_pca(texels, BLOCK_SIZE, e0, e1);

		
	return encode_rgb_single_partition(texels, e0, e1);
}

[RootSignature(RootSig)]
[numthreads(THREAD_NUM_X, THREAD_NUM_Y, 1)] // 一个group里的thread数目
void main(
	// 一个thread处理一个block
	uint3 Gid : SV_GroupID,				// dispatch里的group坐标
	uint3 GTid : SV_GroupThreadID,		// group里的thread坐标
	uint3 DTid : SV_DispatchThreadID,	// DispatchThreadID = (GroupID X numthreads) + GroupThreadID
	uint Gidx : SV_GroupIndex)			// group里的thread坐标展开后的索引
{
	// DTid.xy 就是block坐标（第几个block）
	uint2 blockSize = uint2(BLOCK_SIZE_X, BLOCK_SIZE_Y);
	uint2 blockPos = DTid.xy;

	uint4 texels[BLOCK_SIZE];
	uint i = 0;
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		uint y = i / BLOCK_SIZE_X;
		uint x = i - y * BLOCK_SIZE_X;
		uint2 localPos = uint2(x, y);
		uint3 pixelPos = uint3(blockPos * blockSize + localPos, 0);
		pixelPos.y = TexelHeight - 1 - pixelPos.y;
		uint4 pixel = g_SrcTex.Load(pixelPos) * 255;
		pixel = clamp(pixel, 0, 255);
		texels[i] = pixel;
	}

	uint4 phy_blk = compress(texels);

	uint blockID = blockPos.y * xGroupNum * THREAD_NUM_X + blockPos.x;
	g_DstBuf[blockID] = phy_blk;

	// draw to backbuffer
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		uint y = i / BLOCK_SIZE_X;
		uint x = i - y * BLOCK_SIZE_X;
		uint2 localPos = uint2(x, y);
		float2 pixel_coord = blockPos * blockSize + localPos;
		pixel_coord.y = TexelHeight - 1 - pixel_coord.y;
		g_DstTex[pixel_coord] = texels[i] / 255.0;
	}

}

