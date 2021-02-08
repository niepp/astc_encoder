
#define UNROLL ;

//#define FAST 1

#define THREAD_NUM_X 8
#define THREAD_NUM_Y 8

#define BLOCK_SIZE_X	4
#define BLOCK_SIZE_Y	4
#define BLOCK_SIZE		(BLOCK_SIZE_X * BLOCK_SIZE_Y)
#define BLOCK_BYTES		16

#define MAX_MIPSNUM		12



int InTexelHeight;
int InGroupNumX;

Texture2D InTexture;
RWStructuredBuffer<uint4> OutBuffer;

//#include "Common.ush"
//#include "GammaCorrectionCommon.ush"

#include "ASTC_Define.hlsl"
#include "ASTC_Table.hlsl"
#include "ASTC_IntegerSequenceEncoding.hlsl"

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// calc the dominant axis
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
float4 mean(uint4 texels[BLOCK_SIZE], int count)
{
	uint4 sum = uint4(0, 0, 0, 0);
	for (int i = 0; i < count; ++i)
	{
		sum += texels[i];
	}
	float4 m = float4(sum.x, sum.y, sum.z, sum.w);
	return m / count;
}

float4x4 covariance(float4 m[BLOCK_SIZE], int count)
{
	float inv = 1.0 / (count - 1);
	float4x4 cov;
	for (int i = 0; i < 4; ++i)
	{
		for (int j = 0; j < 4; ++j)
		{
			float s = 0;
			for (int k = 0; k < count; ++k)
			{
				float4 p = m[k];
				s += p[i] * p[j];
			}
			cov[i][j] = s * inv;
		}
	}
	return cov;
}

float4 eigen_vector(float4x4 m)
{
	// calc the max eigen value by iteration
	float4 v = normalize(float4(1, 3, 2, 0));
	for (int i = 0; i < 8; ++i)
	{
		v = mul(m, v);
		if (length(v) < SMALL_VALUE)
		{
			return v;
		}
		v = normalize(mul(m, v));
	}
	return v;
}

void principal_component_analysis(uint4 texels[BLOCK_SIZE], uint hasalpha, out float4 e0, out float4 e1)
{
	float4 pt_mean = mean(texels, BLOCK_SIZE);

	float4 sub[BLOCK_SIZE];
	int i = 0;
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		sub[i] = texels[i] - pt_mean;
	}

	float4x4 cov = covariance(sub, BLOCK_SIZE);

	float4 vec_k = eigen_vector(cov);

	// if the direction-vector ends up pointing from light to dark, FLIP IT!
	// this will make the first endpoint the darkest one.
	if (vec_k.x + vec_k.y + vec_k.z < 0.0f)
	{
		vec_k = -vec_k;
	}

	float a = 1e31;
	float b = -1e31;
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		float t = dot(sub[i], vec_k);
		a = min(a, t);
		b = max(b, t);
	}

	e0 = clamp(vec_k * a + pt_mean, 0.0, 255.0);
	e1 = clamp(vec_k * b + pt_mean, 0.0, 255.0);
	
	if (hasalpha == 0)
	{
		e0.a = 255.0;
		e1.a = 255.0;
	}

}
void max_accumulation_pixel_direction(uint4 texels[BLOCK_SIZE], uint hasalpha, out float4 e0, out float4 e1)
{
	float4 pt_mean = mean(texels, BLOCK_SIZE);

	float4 sum_r = float4(0,0,0,0);
	float4 sum_g = float4(0,0,0,0);
	float4 sum_b = float4(0,0,0,0);
	float4 sum_a = float4(0,0,0,0);
	UNROLL
	for (int i = 0; i < BLOCK_SIZE; ++i)
	{
		float4 dt = texels[i] - pt_mean;
		sum_r += (dt.x > 0) ? dt : 0;
		sum_g += (dt.y > 0) ? dt : 0;
		sum_b += (dt.z > 0) ? dt : 0;
		sum_a += (dt.w > 0) ? dt : 0;
	}

	float dot_r = dot(sum_r, sum_r);
	float dot_g = dot(sum_g, sum_g);
	float dot_b = dot(sum_b, sum_b);
	float dot_a = dot(sum_a, sum_a);

	float maxdot = dot_r;
	float4 vec_k = sum_r;

	if (dot_g > maxdot)
	{
		vec_k = sum_g;
		maxdot = dot_g;
	}

	if (dot_b > maxdot)
	{
		vec_k = sum_b;
		maxdot = dot_b;
	}

	if (hasalpha && dot_a > maxdot)
	{
		vec_k = sum_a;
		maxdot = dot_a;
	}

	// safe normalize
	float lenk = length(vec_k);
	vec_k = (lenk < SMALL_VALUE) ? vec_k : normalize(vec_k);

	float sumk = vec_k.x + vec_k.y + vec_k.z;
	vec_k = (sumk < 0.0f) ? -vec_k : vec_k;

	float a = 1e31;
	float b = -1e31;
	UNROLL
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		float t = dot(texels[i] - pt_mean, vec_k);
		a = min(a, t);
		b = max(b, t);
	}

	e0 = clamp(vec_k * a + pt_mean, 0.0, 255.0);
	e1 = clamp(vec_k * b + pt_mean, 0.0, 255.0);

	if (hasalpha == 0)
	{
		e0.a = 255.0;
		e1.a = 255.0;
	}
}

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// quantize & unquantize the endpoints
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
uint4 quantize_color(uint qm_index, uint4 c)
{
	uint4 result;
	result.r = color_quantize_table[qm_index * COLOR_QUANTIZE_NUM + c.r];
	result.g = color_quantize_table[qm_index * COLOR_QUANTIZE_NUM + c.g];
	result.b = color_quantize_table[qm_index * COLOR_QUANTIZE_NUM + c.b];
	result.a = color_quantize_table[qm_index * COLOR_QUANTIZE_NUM + c.a];
	return result;
}

uint4 unquantize_color(uint qm_index, uint4 c)
{
	uint4 result;
	result.r = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + c.r];
	result.g = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + c.g];
	result.b = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + c.b];
	result.a = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + c.a];
	return result;
}

void encode_color(uint qm_index, float4 e0, float4 e1, out uint endpoint_quantized[8])
{
	uint4 e0q = quantize_color(qm_index, round(e0));
	uint4 e1q = quantize_color(qm_index, round(e1));

	uint4 e0u = unquantize_color(qm_index, e0q);
	uint4 e1u = unquantize_color(qm_index, e1q);

	// Sort the endpoints to ensure that the normal encoding is used.
	if (sum(e0u.rgb) > sum(e1u.rgb))
	{
		swap(e0q, e1q);
	}

	endpoint_quantized[0] = e0q.r;
	endpoint_quantized[1] = e1q.r;
	endpoint_quantized[2] = e0q.g;
	endpoint_quantized[3] = e1q.g;
	endpoint_quantized[4] = e0q.b;
	endpoint_quantized[5] = e1q.b;
	endpoint_quantized[6] = e0q.a;
	endpoint_quantized[7] = e1q.a;
}

void decode_color(uint qm_index, uint endpoint_quantized[8], out float4 e0, out float4 e1)
{
	uint ir0 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[0]];
	uint ir1 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[1]];
	uint ig0 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[2]];
	uint ig1 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[3]];
	uint ib0 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[4]];
	uint ib1 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[5]];
	uint a0 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[6]];
	uint a1 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[7]];

	e0 = float4(ir0, ig0, ib0, a0);
	e1 = float4(ir1, ig1, ib1, a1);

	if (ir0 + ig0 + ib0 > ir1 + ig1 + ib1)
	{
		swap(e0, e1);
	}

}


//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// calculate quantized weights
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
uint quantize_weight(uint weight_range, float weight)
{
	uint r = (weight_range - 1);
	float u = clamp(weight, 0.0, 1.0) * r;
	uint q = round(u);
	return clamp(q, 0, r);
}

float unquantize_weight(uint weight_range, uint qw)
{
	float w = 1.0 * qw / (weight_range - 1);
	return clamp(w, 0.0, 1.0);
}

void calculate_quantized_weights(uint4 texels[BLOCK_SIZE],
	uint weight_range,
	float4 ep0,
	float4 ep1,
	inout uint weights[16])
{
	int i = 0;
	float4 vec_k = ep1 - ep0;
	int squdist = dot(vec_k, vec_k);
	if (squdist > 0)
	{
		vec_k = normalize(vec_k);
		float minw = 1e31;
		float maxw = -1e31;
		float projw[BLOCK_SIZE];

		UNROLL
		for (i = 0; i < BLOCK_SIZE; ++i)
		{
			projw[i] = dot(vec_k, texels[i] - ep0);
			minw = min(projw[i], minw);
			maxw = max(projw[i], maxw);
		}

		float len = maxw - minw;
		len = max(SMALL_VALUE, len);
		float invlen = 1.0 / len;
		UNROLL
		for (i = 0; i < 16; ++i)
		{
			weights[i] = quantize_weight(weight_range, (projw[i] - minw) * invlen);
		}
	}
}

void lerp_colors_by_weights(uint weights_quantized[16], uint weight_range, float4 ep0, float4 ep1, out float4 decode_texels[BLOCK_SIZE])
{
	UNROLL
	for (int i = 0; i < BLOCK_SIZE; ++i)
	{
		float w = unquantize_weight(weight_range, weights_quantized[i]);
		decode_texels[i] = lerp(ep0, ep1, w);
	}
}



//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// encode single partition
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// candidate blockmode int4(weights quantmethod, endpoints quantmethod, weights range, endpoints quantmethod index of table)

#define BLOCK_MODE_NUM 10
static const uint4 block_modes[2][BLOCK_MODE_NUM] =
{
	{ // CEM_LDR_RGB_DIRECT
		uint4(QUANT_3, QUANT_256, 3, 7),
		uint4(QUANT_4, QUANT_256, 4, 7),
		uint4(QUANT_5, QUANT_256, 5, 7),
		uint4(QUANT_6, QUANT_256, 6, 7),
		uint4(QUANT_8, QUANT_256, 8, 7),
		uint4(QUANT_12, QUANT_256, 12, 7),
		uint4(QUANT_16, QUANT_192, 16, 6),
		uint4(QUANT_20, QUANT_96, 20, 5),
		uint4(QUANT_24, QUANT_64, 24, 4),
		uint4(QUANT_32, QUANT_32, 32, 2),
	},

	{ // CEM_LDR_RGBA_DIRECT
		uint4(QUANT_3, QUANT_256, 3, 7),
		uint4(QUANT_4, QUANT_256, 4, 7),
		uint4(QUANT_5, QUANT_256, 5, 7),
		uint4(QUANT_6, QUANT_256, 6, 7),
		uint4(QUANT_8, QUANT_192, 8, 6),
		uint4(QUANT_12, QUANT_96, 12, 5),
		uint4(QUANT_16, QUANT_48, 16, 3),
		uint4(QUANT_20, QUANT_32, 20, 2),
		uint4(QUANT_24, QUANT_24, 24, 1),
		uint4(QUANT_32, QUANT_12, 32, 0),
	}
};


void choose_best_quantmethod(uint4 texels[BLOCK_SIZE], float4 ep0, float4 ep1, uint hasalpha, out uint4 best_blockmode)
{
	float minerr = 1e31;
	UNROLL
	for (int k = 0; k < BLOCK_MODE_NUM; ++k)
	{
		// encode
		uint4 blockmode = (hasalpha > 0) ? block_modes[1][k] : block_modes[0][k];		
		uint wt_range = blockmode.z;
		uint cq_index = blockmode.w;

		uint endpoints_quantized[8] = {0,0,0,0,0,0,0,0};
		uint weights_quantized[16] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
		encode_color(cq_index, ep0, ep1, endpoints_quantized);
		calculate_quantized_weights(texels, wt_range, ep0, ep1, weights_quantized);

		// decode
		float4 decode_ep0 = 0;
		float4 decode_ep1 = 0;
		decode_color(cq_index, endpoints_quantized, decode_ep0, decode_ep1);
		float4 decode_texels[BLOCK_SIZE];
		lerp_colors_by_weights(weights_quantized, wt_range, decode_ep0, decode_ep1, decode_texels);

		// compare the decode texels and origin
		float sum = 0;
		UNROLL
		for (int i = 0; i < BLOCK_SIZE; ++i)
		{
			float4 diff = texels[i] - decode_texels[i];
			float squlen = dot(diff, diff);
			sum += squlen;
		}

		if (sum < minerr)
		{
			minerr = sum;
			best_blockmode = blockmode;
		}

	}

}

uint4 assemble_block(uint blockmode, uint color_endpoint_mode, uint partition_count, uint partition_index, uint ep_ise[16], uint ep_bitcnt, uint outs[16]/*weight bise code*/, uint wt_bitcnt)
{
	int i = 0;
	int wt_count = (wt_bitcnt + 7) / 8;
	int j = wt_count - 1;
	UNROLL
	for (; i < j; ++i, --j)
	{
		swap(outs[i], outs[j]);
	}

	UNROLL
	for (i = 0; i < wt_count; ++i)
	{
		outs[i] = reverse_byte(outs[i]);
	}

	i = BLOCK_BYTES - 1;
	j = wt_count - 1;
	int end = BLOCK_BYTES - wt_count - 1;
	UNROLL
	for (; i > end; --i, --j)
	{
		outs[i] = outs[j];
		outs[j] = 0;
	}


	uint bitpos = 0;
	orbits8_ptr(blockmode & 0xFF,		 8, outs, bitpos);
	orbits8_ptr((blockmode >> 8) & 0xFF, 3, outs, bitpos);
	orbits8_ptr(partition_count - 1,	 2, outs, bitpos);

	// CEM
	uint cem_bits = 4;

	//if (partition_count > 1)
	//{
	//	phy_blk = orbits8_ptr(phy_blk, 13, partition_index & 63, 6);
	//	phy_blk = orbits8_ptr(phy_blk, 19, partition_index >> 6, 4);
	//	cem_bits = 6;
	//}

	orbits8_ptr(color_endpoint_mode, cem_bits, outs, bitpos);

	for (i = 0; i < 8; ++i)
	{
		int idx = bitpos / 8;
		uint offset = bitpos % 8;
		uint mask = (ep_ise[i] << offset);
		outs[idx] |= mask & 0xFF;
		outs[idx + 1] |= (mask >> 8) & 0xFF;
		bitpos += 8;
	}

	uint4 phy_blk = array16_2_uint4(outs);

	return phy_blk;

}

uint4 encode_block(uint4 texels[BLOCK_SIZE], uint hasalpha)
{
	float4 ep0, ep1;
	//principal_component_analysis(texels, hasalpha, ep0, ep1);
	max_accumulation_pixel_direction(texels, hasalpha, ep0, ep1);

	uint4 best_blockmode = (hasalpha > 0) ? uint4(QUANT_6, QUANT_256, 6, 7) : uint4(QUANT_8, QUANT_256, 8, 7);
#if (FAST == 0)
	choose_best_quantmethod(texels, ep0, ep1, hasalpha, best_blockmode);
#endif

	// endpoints_quant是根据整个128bits减去weights的编码占用和其他配置占用后剩余的bits位数来确定的。
	uint weight_quantmethod = best_blockmode.x;
	uint endpoint_quantmethod = best_blockmode.y;
	uint weight_range = best_blockmode.z;
	uint colorquant_index = best_blockmode.w;

	uint color_endpoint_mode = (hasalpha > 0) ? CEM_LDR_RGBA_DIRECT : CEM_LDR_RGB_DIRECT;

	// reference from arm astc encoder "symbolic_to_physical"
	uint bytes_of_one_endpoint = 2 * (color_endpoint_mode >> 2) + 2;

	// for single partition
	uint partition_index = 0;
	uint partition_count = 1;

/*
	the first row of "Table C.2.8 - 2D Block Mode Layout".
	------------------------------------------------------------------------
	10  9   8   7   6   5   4   3   2   1   0   Width Height Notes
	------------------------------------------------------------------------
	D   H     B       A     R0  0   0   R2  R1  B + 4   A + 2
*/

	uint a = Y_GRIDS - 2;
	uint b = X_GRIDS - 4;

	a &= 0x3;
	b &= 0x3;

	uint d = 0;  // dual plane

	// more details from "Table C.2.7 - Weight Range Encodings"
	// "a precision bit H"
	const uint h_table[MAX_WEIGHT_RANGE_NUM] = { 0, 0, 0, 0, 0, 0,
												 1, 1, 1, 1, 1, 1 };

	// "The weight ranges are encoded using a 3 bit value R"
	const uint r_table[MAX_WEIGHT_RANGE_NUM] = { 0x2, 0x3, 0x4, 0x5, 0x6, 0x7,
												 0x2, 0x3, 0x4, 0x5, 0x6, 0x7 };

	uint h = h_table[weight_quantmethod];
	uint r = r_table[weight_quantmethod];

	// block mode
	int blockmode = (r >> 1) & 0x3;
	blockmode |= (r & 0x1) << 4;
	blockmode |= (a & 0x3) << 5;
	blockmode |= (b & 0x3) << 7;
	blockmode |= h << 9;
	blockmode |= d << 10;

	// encode endpoints
	uint endpoints_quantized[8] = {0,0,0,0,0,0,0,0};
	encode_color(colorquant_index, ep0, ep1, endpoints_quantized);

	// encode weights
	uint weights_quantized[16] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
	calculate_quantized_weights(texels, weight_range, ep0, ep1, weights_quantized);

	UNROLL
	for (int i = 0; i < 16; ++i)
	{
		weights_quantized[i] = scramble_table[weight_quantmethod * WEIGHT_QUANTIZE_NUM + weights_quantized[i]];
	}
	
	uint ep_ise[16] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
	uint ep_bitcnt = 0;
	uint wt_ise[16] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
	uint wt_bitcnt = 0;
#if (FAST == 0)
	// endpoints_quantized ise encode
	bise_endpoints(endpoints_quantized, hasalpha, endpoint_quantmethod, ep_ise, ep_bitcnt);

	// weights_quantized ise encode
	bise_weights(weights_quantized, weight_quantmethod, wt_ise, wt_bitcnt);
#else
	ep_bitcnt = 0;
	uint bits = bits_trits_quints_table[endpoint_quantmethod * 3 + 0];
	UNROLL
	for (i = 0; i < 8; ++i)
	{
		int idx = ep_bitcnt / 8;
		uint offset = ep_bitcnt % 8;
		uint mask = (endpoints_quantized[i] << offset);
		ep_ise[idx] |= mask & 0xFF;
		ep_ise[idx + 1] |= (mask >> 8) & 0xFF;
		ep_bitcnt += bits;
	}

	wt_bitcnt = 0;
	bits = bits_trits_quints_table[weight_quantmethod * 3 + 0];
	UNROLL
	for (i = 0; i < 16; ++i)
	{
		int idx = wt_bitcnt / 8;
		uint offset = wt_bitcnt % 8;
		uint mask = (weights_quantized[i] << offset);
		wt_ise[idx] |= mask & 0xFF;
		wt_ise[idx + 1] |= (mask >> 8) & 0xFF;
		wt_bitcnt += bits;
	}
#endif

	// assemble to astcblock
	return assemble_block(blockmode, color_endpoint_mode, partition_count, partition_index, ep_ise, ep_bitcnt, wt_ise, wt_bitcnt);

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

	int2 blockSize = uint2(BLOCK_SIZE_X, BLOCK_SIZE_Y);

	uint4 texels[BLOCK_SIZE];
	uint hasalpha = 0;
	int i = 0;
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		int y = i / BLOCK_SIZE_X;
		int x = i - y * BLOCK_SIZE_X;
		int2 localPos = uint2(x, y);
		int3 pixelPos = uint3(blockPos * blockSize + localPos, 0);
		pixelPos.y = InTexelHeight - 1 - pixelPos.y;
		uint4 pixel = InTexture.Load(pixelPos) * 255;
		pixel = clamp(pixel, 0, 255);
		hasalpha |= (pixel.a != 255) ? 1 : 0;
		texels[i] = pixel;
	}

	uint4 phy_blk = encode_block(texels, hasalpha);

	//uint blockID = blockPos.y * InGroupNumX * THREAD_NUM_X + blockPos.x;
	uint blockID = blockPos.y * 256 + blockPos.x;
	OutBuffer[blockID] = phy_blk;

}

