

int InTexelHeight;
int InGroupNumX;

Texture2D InTexture;
RWStructuredBuffer<uint4> OutBuffer;

#define THREAD_NUM_X 8
#define THREAD_NUM_Y 8

//#include "Common.ush"


#include "ASTC_Define.hlsl"
#include "ASTC_Table.hlsl"
#include "ASTC_WeightsQuantize.hlsl"
#include "ASTC_IntegerSequenceEncoding.hlsl"


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

void principal_component_analysis(uint4 texels[BLOCK_SIZE], uint count, out float3 line_k, out float3 line_m)
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

uint3 quantize_color(uint quant, uint3 c)
{
	uint3 result;
	result.r = color_quantize_table[c.r];
	result.g = color_quantize_table[c.g];
	result.b = color_quantize_table[c.b];
	return result;
}

uint3 unquantize_color(uint quant, uint3 c)
{
	uint3 result;
	result.r = color_unquantize_table[c.r];
	result.g = color_unquantize_table[c.g];
	result.b = color_unquantize_table[c.b];
	return result;
}


void encode_rgb_direct(uint endpoints_quantmethod, uint3 e0, uint3 e1, out uint endpoint_quantized[6])
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

	uint x_grids = BLOCK_SIZE_X;
	uint y_grids = BLOCK_SIZE_Y;
	uint weight_quantmethod = 5;

	uint block_mode = 19; //encode_block_mode(BLOCK_SIZE_X, BLOCK_SIZE_Y, x_grids, y_grids, weight_quantmethod);

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

	uint4 ret = symbolic_to_physical(color_endpoint_mode, endpoints_quantmethod, weight_quantmethod, partition_count, partition_index, endpoint_ise, weights_ise);

	return ret;

}



uint4 compress(uint4 texels[BLOCK_SIZE])
{
	float3 e0, e1;
	compute_dominant_direction_pca(texels, BLOCK_SIZE, e0, e1);

    uint4 blk = encode_rgb_single_partition(texels, e0, e1);

	return blk;

}


[numthreads(THREAD_NUM_X, THREAD_NUM_Y, 1)] // 一个group里的thread数目
void MainCS(
	// 一个thread处理一个block
	uint3 Gid : SV_GroupID,				// dispatch里的group坐标
	uint3 GTid : SV_GroupThreadID,		// group里的thread坐标
	uint3 DTid : SV_DispatchThreadID,	// DispatchThreadID = (GroupID X numthreads) + GroupThreadID
	uint Gidx : SV_GroupIndex)			// group里的thread坐标展开后的索引
{
	// DTid.xy 就是block坐标（第几个block）

	uint2 blockPos = DTid.xy;


	uint2 blockSize = uint2(BLOCK_SIZE_X, BLOCK_SIZE_Y);

	uint4 texels[BLOCK_SIZE];
	uint i = 0;
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		uint y = i / BLOCK_SIZE_X;
		uint x = i - y * BLOCK_SIZE_X;
		uint2 localPos = uint2(x, y);
		uint3 pixelPos = uint3(blockPos * blockSize + localPos, 0);
		pixelPos.y = InTexelHeight - 1 - pixelPos.y;
		uint4 pixel = InTexture.Load(pixelPos) * 255;
		pixel = clamp(pixel, 0, 255);
		texels[i] = pixel;
	}

	uint4 phy_blk = compress(texels);

	uint blockID = blockPos.y * InGroupNumX * THREAD_NUM_X + blockPos.x;
	OutBuffer[blockID] = phy_blk;

}

