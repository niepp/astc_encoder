#ifndef MAX_MIPS_NUM
#define MAX_MIPS_NUM 14
#endif

#ifndef THREAD_NUM_X
#define THREAD_NUM_X 8
#endif

#ifndef THREAD_NUM_Y
#define THREAD_NUM_Y 8
#endif

#include "ASTC_Define.hlsl"
#include "ASTC_Table.hlsl"
#include "ASTC_IntegerSequenceEncoding.hlsl"

cbuffer constData : register(b0)
{
	int InTexelHeight;
	int InTexelWidth;
	int InGroupNumX;
};

Texture2D InTexture;
RWStructuredBuffer<uint4> OutBuffer;

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// calc the dominant axis
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
float4 eigen_vector(float4x4 m)
{
	// calc the max eigen value by iteration
	float4 v = float4(0.26726f, 0.80178f, 0.53452f, 0.0f);
	for (int i = 0; i < 8; ++i)
	{
		v = mul(m, v);
		if (length(v) < SMALL_VALUE) {
			return v;
		}
		v = normalize(mul(m, v));
	}
	return v;
}

void find_min_max(float4 texels[BLOCK_SIZE], float4 pt_mean, float4 vec_k, out float4 e0, out float4 e1)
{
	float a = 1e31f;
	float b = -1e31f;
	for (int i = 0; i < BLOCK_SIZE; ++i)
	{
		float4 texel = texels[i] - pt_mean;
		float t = dot(texel, vec_k);
		a = min(a, t);
		b = max(b, t);
	}

	e0 = clamp(vec_k * a + pt_mean, 0.0f, 255.0f);
	e1 = clamp(vec_k * b + pt_mean, 0.0f, 255.0f);

	// if the direction-vector ends up pointing from light to dark, FLIP IT!
	// this will make the first endpoint the darkest one.
	float4 e0u = round(e0);
	float4 e1u = round(e1);
	if (e0u.x + e0u.y + e0u.z > e1u.x + e1u.y + e1u.z)
	{
		swap(e0, e1);
	}

#if !HAS_ALPHA
	e0.a = 255.0f;
	e1.a = 255.0f;
#endif

}

void principal_component_analysis(float4 texels[BLOCK_SIZE], out float4 e0, out float4 e1)
{
	int i = 0;
	float4 pt_mean = 0;
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		pt_mean += texels[i];
	}
	pt_mean /= BLOCK_SIZE;

	float4x4 cov = 0;
	float s = 0;
	for (int k = 0; k < BLOCK_SIZE; ++k)
	{
		float4 texel = texels[k] - pt_mean;
		for (i = 0; i < 4; ++i)
		{
			for (int j = 0; j < 4; ++j)
			{
				cov[i][j] += texel[i] * texel[j];
			}
		}
	}
	cov /= BLOCK_SIZE - 1;

	float4 vec_k = eigen_vector(cov);

	find_min_max(texels, pt_mean, vec_k, e0, e1);

}

void max_accumulation_pixel_direction(float4 texels[BLOCK_SIZE], out float4 e0, out float4 e1)
{
	int i = 0;
	float4 pt_mean = 0;
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		pt_mean += texels[i];
	}
	pt_mean /= BLOCK_SIZE;

	float4 sum_r = float4(0,0,0,0);
	float4 sum_g = float4(0,0,0,0);
	float4 sum_b = float4(0,0,0,0);
	float4 sum_a = float4(0,0,0,0);
	for (i = 0; i < BLOCK_SIZE; ++i)
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

#if HAS_ALPHA
	if (dot_a > maxdot)
	{
		vec_k = sum_a;
		maxdot = dot_a;
	}
#endif

	// safe normalize
	float lenk = length(vec_k);
	vec_k = (lenk < SMALL_VALUE) ? vec_k : normalize(vec_k);

	find_min_max(texels, pt_mean, vec_k, e0, e1);

}

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// quantize & unquantize the endpoints
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#if !FAST
uint quantize_byte(uint qm_index, uint v)
{
	uint u = qm_index * COLOR_QUANTIZE_NUM * 4 + v;
	uint offset = (u & 3) << 3;
	return (color_quantize_table[u / 4] >> offset) & 255;
}

uint unquantize_byte(uint qm_index, uint v)
{
	uint u = qm_index * COLOR_QUANTIZE_NUM * 4 + v;
	uint offset = (u & 3) << 3;
	return (color_unquantize_table[u / 4] >> offset) & 255;
}

uint4 quantize_color(uint qm_index, uint4 c)
{
	uint4 result;
	result.r = quantize_byte(qm_index, c.r);
	result.g = quantize_byte(qm_index, c.g);
	result.b = quantize_byte(qm_index, c.b);
	result.a = quantize_byte(qm_index, c.a);
	return result;
}

uint4 unquantize_color(uint qm_index, uint4 c)
{
	uint4 result;
	result.r = unquantize_byte(qm_index, c.r);
	result.g = unquantize_byte(qm_index, c.g);
	result.b = unquantize_byte(qm_index, c.b);
	result.a = unquantize_byte(qm_index, c.a);
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
	uint ir0 = unquantize_byte(qm_index, endpoint_quantized[0]);
	uint ir1 = unquantize_byte(qm_index, endpoint_quantized[1]);
	uint ig0 = unquantize_byte(qm_index, endpoint_quantized[2]);
	uint ig1 = unquantize_byte(qm_index, endpoint_quantized[3]);
	uint ib0 = unquantize_byte(qm_index, endpoint_quantized[4]);
	uint ib1 = unquantize_byte(qm_index, endpoint_quantized[5]);
	uint a0 = unquantize_byte(qm_index, endpoint_quantized[6]);
	uint a1 = unquantize_byte(qm_index, endpoint_quantized[7]);

	e0 = float4(ir0, ig0, ib0, a0);
	e1 = float4(ir1, ig1, ib1, a1);

	if (ir0 + ig0 + ib0 > ir1 + ig1 + ib1)
	{
		swap(e0, e1);
	}

}
#else // for QUANT_256 quantization
void encode_color(uint qm_index, float4 e0, float4 e1, out uint endpoint_quantized[8])
{
	uint4 e0q = round(e0);
	uint4 e1q = round(e1);
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
	e0 = float4(endpoint_quantized[0], endpoint_quantized[2], endpoint_quantized[4], endpoint_quantized[6]);
	e1 = float4(endpoint_quantized[1], endpoint_quantized[3], endpoint_quantized[5], endpoint_quantized[7]);
}
#endif


//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// calculate quantized weights
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
uint quantize_weight(uint weight_range, float weight)
{
	uint q = round(weight * weight_range);
	return clamp(q, 0, weight_range);
}

float unquantize_weight(uint weight_range, uint qw)
{
	float w = 1.0 * qw / weight_range;
	return clamp(w, 0.0, 1.0);
}

static const uint4 idx_grids[16] = {
	uint4(0, 1, 6, 7),
	uint4(1, 2, 7, 8),
	uint4(3, 4, 9, 10),
	uint4(4, 5, 10, 11),
	uint4(6, 7, 12, 13),
	uint4(7, 8, 13, 14),
	uint4(9, 10, 15, 16),
	uint4(10, 11, 16, 17),
	uint4(18, 19, 24, 25),
	uint4(19, 20, 25, 26),
	uint4(21, 22, 27, 28),
	uint4(22, 23, 28, 29),
	uint4(24, 25, 30, 31),
	uint4(25, 26, 31, 32),
	uint4(27, 28, 33, 34),
	uint4(28, 29, 34, 35),
};

static const float4 wt_grids[16] = {
	float4(0.444, 0.222, 0.222, 0.111),
	float4(0.222, 0.444, 0.111, 0.222),
	float4(0.444, 0.222, 0.222, 0.111),
	float4(0.222, 0.444, 0.111, 0.222),
	float4(0.222, 0.111, 0.444, 0.222),
	float4(0.111, 0.222, 0.222, 0.444),
	float4(0.222, 0.111, 0.444, 0.222),
	float4(0.111, 0.222, 0.222, 0.444),
	float4(0.444, 0.222, 0.222, 0.111),
	float4(0.222, 0.444, 0.111, 0.222),
	float4(0.444, 0.222, 0.222, 0.111),
	float4(0.222, 0.444, 0.111, 0.222),
	float4(0.222, 0.111, 0.444, 0.222),
	float4(0.111, 0.222, 0.222, 0.444),
	float4(0.222, 0.111, 0.444, 0.222),
	float4(0.111, 0.222, 0.222, 0.444),
};


float4 sample_texel(float4 texels[BLOCK_SIZE], uint4 index, float4 coff)
{
	float4 sum = texels[index.x] * coff.x;
	sum += texels[index.y] * coff.y;
	sum += texels[index.z] * coff.z;
	sum += texels[index.w] * coff.w;
	return sum;
}

void calculate_normal_weights(float4 texels[BLOCK_SIZE],
	float4 ep0,
	float4 ep1,
	out float projw[X_GRIDS * Y_GRIDS])
{
	int i = 0;
	float4 vec_k = ep1 - ep0;
	if (length(vec_k) < SMALL_VALUE)
	{
		for (i = 0; i < X_GRIDS * Y_GRIDS; ++i)
		{
			projw[i] = 0;
		}
	}
	else
	{
		vec_k = normalize(vec_k);
		float minw = 1e31f;
		float maxw = -1e31f;
#if BLOCK_6X6

/* bilinear interpolation: GirdSize is 4，BlockSize is 6

	0     1     2     3     4     5
|-----|-----|-----|-----|-----|-----|
|--------|--------|--------|--------|
    0        1        2        3
*/
		for (i = 0; i < X_GRIDS * Y_GRIDS; ++i)
		{
			float4 sum = sample_texel(texels, idx_grids[i], wt_grids[i]);
			float w = dot(vec_k, sum - ep0);
			minw = min(w, minw);
			maxw = max(w, maxw);
			projw[i] = w;
		}
#else
		// ensure "X_GRIDS * Y_GRIDS == BLOCK_SIZE"
		for (i = 0; i < BLOCK_SIZE; ++i)
		{
			float4 texel = texels[i];
			float w = dot(vec_k, texel - ep0);
			minw = min(w, minw);
			maxw = max(w, maxw);
			projw[i] = w;
		}
#endif

		float invlen = maxw - minw;
		invlen = max(SMALL_VALUE, invlen);
		invlen = 1.0f / invlen;
		for (i = 0; i < X_GRIDS * Y_GRIDS; ++i)
		{
			projw[i] = (projw[i] - minw) * invlen;
		}
	}
}

void quantize_weights(float projw[X_GRIDS * Y_GRIDS],
	uint weight_range,
	out uint weights[X_GRIDS * Y_GRIDS])
{
	for (int i = 0; i < X_GRIDS * Y_GRIDS; ++i)
	{
		weights[i] = quantize_weight(weight_range, projw[i]);
	}
}

void calculate_quantized_weights(float4 texels[BLOCK_SIZE],
	uint weight_range,
	float4 ep0,
	float4 ep1,
	out uint weights[X_GRIDS * Y_GRIDS])
{
	float projw[X_GRIDS * Y_GRIDS];
	calculate_normal_weights(texels, ep0, ep1, projw);
	quantize_weights(projw, weight_range, weights);
}

#if !FAST
void calculate_texelsweights(float4 texels[BLOCK_SIZE],
	float4 ep0,
	float4 ep1,
	out float projw[X_GRIDS * Y_GRIDS])
{
	int i = 0;
	float4 vec_k = ep1 - ep0;
	if (length(vec_k) < SMALL_VALUE)
	{
		for (i = 0; i < X_GRIDS * Y_GRIDS; ++i)
		{
			projw[i] = 0;
		}
	}
	else
	{
		vec_k = normalize(vec_k);
		float minw = 1e31f;
		float maxw = -1e31f;
#if BLOCK_6X6
		for (i = 0; i < X_GRIDS * Y_GRIDS; ++i)
		{
			float4 sum = sample_texel(texels, idx_grids[i], wt_grids[i]);
			float w = dot(vec_k, sum - ep0);
			minw = min(w, minw);
			maxw = max(w, maxw);
			projw[i] = w;
		}
#else
		for (i = 0; i < BLOCK_SIZE; ++i)
		{
			float w = dot(vec_k, texels[i] - ep0);
			minw = min(w, minw);
			maxw = max(w, maxw);
			projw[i] = w;
		}
#endif

		float invlen = maxw - minw;
		invlen = max(SMALL_VALUE, invlen);
		invlen = 1.0 / invlen;
		for (i = 0; i < X_GRIDS * Y_GRIDS; ++i)
		{
			projw[i] = (projw[i] - minw) * invlen;
		}
	}
}

static const float2 wt_lerp[6] = {
	float2(1.0f, 0.0f),
	float2(0.5f, 0.5f),
	float2(1.0f, 0.0f),
	float2(1.0f, 0.0f),
	float2(0.5f, 0.5f),
	float2(1.0f, 0.0f),
};

static const uint2 indexmap_lerp[6] = {
	uint2(0, 0),
	uint2(0, 1),
	uint2(1, 1),
	uint2(2, 2),
	uint2(2, 3),
	uint2(3, 3),
};

float sumdiff_of_lerp_colors(float4 texels[BLOCK_SIZE], uint weights_quantized[X_GRIDS * Y_GRIDS], uint weight_range, float4 ep0, float4 ep1)
{
	float sumdiff = 0;
#if BLOCK_6X6
	for (int i = 0; i < BLOCK_SIZE; ++i)
	{
		uint idx = i;
		int row = idx / DIM;
		int col = idx % DIM;

		float wr0 = wt_lerp[row].x;
		float wr1 = wt_lerp[row].y;
		float wc0 = wt_lerp[col].x;
		float wc1 = wt_lerp[col].y;

		int y0 = indexmap_lerp[row].x;
		int y1 = indexmap_lerp[row].y;
		int x0 = indexmap_lerp[col].x;
		int x1 = indexmap_lerp[col].y;

		uint wq00 = weights_quantized[y0 * X_GRIDS + x0];
		uint wq01 = weights_quantized[y0 * X_GRIDS + x1];
		uint wq10 = weights_quantized[y1 * X_GRIDS + x0];
		uint wq11 = weights_quantized[y1 * X_GRIDS + x1];

		float4 wuq;
		wuq.x = unquantize_weight(weight_range, wq00);
		wuq.y = unquantize_weight(weight_range, wq01);
		wuq.z = unquantize_weight(weight_range, wq10);
		wuq.w = unquantize_weight(weight_range, wq11);

		float4 diff = float4(wr0 * wc0, wr0 * wc1, wr1 * wc0, wr1 * wc1);
		float w = dot(diff, wuq);
		diff = lerp(ep0, ep1, w);
		diff -= texels[i];
		sumdiff += dot(diff, diff);
	}
#else
	for (int i = 0; i < BLOCK_SIZE; ++i)
	{
		float w = unquantize_weight(weight_range, weights_quantized[i]);
		float4 diff = lerp(ep0, ep1, w);
		diff -= texels[i];
		sumdiff += dot(diff, diff);
	}
#endif
	return sumdiff;
}
#endif // FAST

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// encode single partition
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// candidate blockmode uint4(weights quantmethod, endpoints quantmethod, weights range, endpoints quantmethod index of table)

#if !FAST
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

void choose_best_quantmethod(float4 texels[BLOCK_SIZE], float4 ep0, float4 ep1, out uint4 best_blockmode)
{
	float minerr = 1e31;

	float projw[X_GRIDS * Y_GRIDS];
	calculate_texelsweights(texels, ep0, ep1, projw);

	for (int k = 0; k < BLOCK_MODE_NUM; ++k)
	{
		// encode
#if HAS_ALPHA
		uint4 blockmode = block_modes[1][k];
#else
		uint4 blockmode = block_modes[0][k];
#endif

		uint endpoints_quantized[8];
		uint weights_quantized[X_GRIDS * Y_GRIDS];
		encode_color(blockmode.w, ep0, ep1, endpoints_quantized);
		quantize_weights(projw,	blockmode.z - 1, weights_quantized);

		// decode
		float4 decode_ep0 = 0;
		float4 decode_ep1 = 0;
		decode_color(blockmode.w, endpoints_quantized, decode_ep0, decode_ep1);
		float sum = sumdiff_of_lerp_colors(texels, weights_quantized, blockmode.z - 1, decode_ep0, decode_ep1);
		if (sum < minerr)
		{
			minerr = sum;
			best_blockmode = blockmode;
		}

	}

}
#endif

uint4 assemble_block(uint blockmode, uint color_endpoint_mode, uint partition_count, uint partition_index, uint4 ep_ise, uint4 wt_ise)
{
	uint4 phy_blk = uint4(0, 0, 0, 0);
	// weights ise
	phy_blk.w |= reverse_byte(wt_ise.x & 0xFF) << 24;
	phy_blk.w |= reverse_byte((wt_ise.x >> 8) & 0xFF) << 16;
	phy_blk.w |= reverse_byte((wt_ise.x >> 16) & 0xFF) << 8;
	phy_blk.w |= reverse_byte((wt_ise.x >> 24) & 0xFF);

	phy_blk.z |= reverse_byte(wt_ise.y & 0xFF) << 24;
	phy_blk.z |= reverse_byte((wt_ise.y >> 8) & 0xFF) << 16;
	phy_blk.z |= reverse_byte((wt_ise.y >> 16) & 0xFF) << 8;
	phy_blk.z |= reverse_byte((wt_ise.y >> 24) & 0xFF);

	phy_blk.y |= reverse_byte(wt_ise.z & 0xFF) << 24;
	phy_blk.y |= reverse_byte((wt_ise.z >> 8) & 0xFF) << 16;
	phy_blk.y |= reverse_byte((wt_ise.z >> 16) & 0xFF) << 8;
	phy_blk.y |= reverse_byte((wt_ise.z >> 24) & 0xFF);

	// blockmode & partition count
	phy_blk.x = blockmode; // blockmode is 11 bit

	//if (partition_count > 1)
	//{
	//	uint endpoint_offset = 29;
	//	uint cem_bits = 6;
	//	uint bitpos = 13;
	//	orbits8_ptr(phy_blk, bitpos, partition_count - 1, 2);
	//	orbits8_ptr(phy_blk, bitpos, partition_index & 63, 6);
	//	orbits8_ptr(phy_blk, bitpos, partition_index >> 6, 4);
	//  ...
	//}

	// cem: color_endpoint_mode is 4 bit
	phy_blk.x |= (color_endpoint_mode & 0xF) << 13;

	// endpoints start from ( multi_part ? bits 29 : bits 17 )
	phy_blk.x |= (ep_ise.x & 0x7FFF) << 17;
	phy_blk.y = ((ep_ise.x >> 15) & 0x1FFFF);
	phy_blk.y |= (ep_ise.y & 0x7FFF) << 17;
	phy_blk.z |= ((ep_ise.y >> 15) & 0x1FFFF);

	return phy_blk;

}

uint assemble_blockmode(uint weight_quantmethod)
{
/*
	the first row of "Table C.2.8 - 2D Block Mode Layout".
	------------------------------------------------------------------------
	10  9   8   7   6   5   4   3   2   1   0   Width Height Notes
	------------------------------------------------------------------------
	D   H     B       A     R0  0   0   R2  R1  B + 4   A + 2
*/

	uint a = (Y_GRIDS - 2) & 0x3;
	uint b = (X_GRIDS - 4) & 0x3;

	uint d = 0;  // dual plane

	// more details from "Table C.2.7 - Weight Range Encodings"	
	uint h = (weight_quantmethod < 6) ? 0 : 1;	// "a precision bit H"
	uint r = (weight_quantmethod % 6) + 2;		// "The weight ranges are encoded using a 3 bit value R"

	// block mode
	uint blockmode = (r >> 1) & 0x3;
	blockmode |= (r & 0x1) << 4;
	blockmode |= (a & 0x3) << 5;
	blockmode |= (b & 0x3) << 7;
	blockmode |= h << 9;
	blockmode |= d << 10;
	return blockmode;
}

uint4 endpoint_ise(uint colorquant_index, float4 ep0, float4 ep1, uint endpoint_quantmethod)
{
	// encode endpoints
	uint ep_quantized[8];
	encode_color(colorquant_index, ep0, ep1, ep_quantized);
#if !HAS_ALPHA
	ep_quantized[6] = 0;
	ep_quantized[7] = 0;
#endif

	// endpoints quantized ise encode
	uint4 ep_ise = 0;
	bise_endpoints(ep_quantized, endpoint_quantmethod, ep_ise);
	return ep_ise;
}

uint4 weight_ise(float4 texels[BLOCK_SIZE], uint weight_range, float4 ep0, float4 ep1, uint  weight_quantmethod)
{
	int i = 0;
	// encode weights
	uint wt_quantized[X_GRIDS * Y_GRIDS];
	calculate_quantized_weights(texels, weight_range, ep0, ep1, wt_quantized);

	for (i = 0; i < X_GRIDS * Y_GRIDS; ++i)
	{
		int w = weight_quantmethod * WEIGHT_QUANTIZE_NUM + wt_quantized[i];
		wt_quantized[i] = scramble_table[w];
	}

	// weights quantized ise encode
	uint4 wt_ise = 0;
	bise_weights(wt_quantized, weight_quantmethod, wt_ise);
	return wt_ise;
}

uint4 encode_block(float4 texels[BLOCK_SIZE])
{
	float4 ep0, ep1;
	principal_component_analysis(texels, ep0, ep1);
	//max_accumulation_pixel_direction(texels, ep0, ep1);

	// endpoints_quant是根据整个128bits减去weights的编码占用和其他配置占用后剩余的bits位数来确定的。
	// for fast compression!
#if HAS_ALPHA
	uint4 best_blockmode = uint4(QUANT_6, QUANT_256, 6, 7);
#else
	uint4 best_blockmode = uint4(QUANT_12, QUANT_256, 12, 7);
#endif

#if !FAST
	choose_best_quantmethod(texels, ep0, ep1, best_blockmode);
#endif

	//uint weight_quantmethod = best_blockmode.x;
	//uint endpoint_quantmethod = best_blockmode.y;
	//uint weight_range = best_blockmode.z;
	//uint colorquant_index = best_blockmode.w;

	// reference to arm astc encoder "symbolic_to_physical"
	//uint bytes_of_one_endpoint = 2 * (color_endpoint_mode >> 2) + 2;

	uint blockmode = assemble_blockmode(best_blockmode.x);

	uint4 ep_ise = endpoint_ise(best_blockmode.w, ep0, ep1, best_blockmode.y);

	uint4 wt_ise = weight_ise(texels, best_blockmode.z - 1, ep0, ep1, best_blockmode.x);

	// assemble to astcblock
#if HAS_ALPHA
	uint color_endpoint_mode = CEM_LDR_RGBA_DIRECT;
#else
	uint color_endpoint_mode = CEM_LDR_RGB_DIRECT;
#endif
	return assemble_block(blockmode, color_endpoint_mode, 1, 0, ep_ise, wt_ise);

}


[numthreads(THREAD_NUM_X, THREAD_NUM_Y, 1)] // 一个group里的thread数目
void MainCS(
	// 一个thread处理一个block
	uint3 Gid : SV_GroupID,				// dispatch里的group坐标
	uint3 GTid : SV_GroupThreadID,		// group里的thread坐标
	uint3 DTid : SV_DispatchThreadID,	// DispatchThreadID = (GroupID X numthreads) + GroupThreadID
	uint Gidx : SV_GroupIndex)			// group里的thread坐标展开后的索引
{
	uint blockID = DTid.y * InGroupNumX * THREAD_NUM_X + DTid.x;
	uint BlockNum = (InTexelWidth + DIM - 1) / DIM;

	float4 texels[BLOCK_SIZE];
	for (int k = 0; k < BLOCK_SIZE; ++k)
	{		
		uint2 blockPos;
		blockPos.y = (uint)(blockID / BlockNum);
		blockPos.x = blockID - blockPos.y * BlockNum;
		
		uint y = k / DIM;
		uint x = k - y * DIM;
		uint2 pixelPos = blockPos * DIM + uint2(x, y);
		float4 texel = InTexture.Load(uint3(pixelPos, 0));
#if IS_NORMALMAP
		texel.b = 1.0f;
		texel.a = 1.0f;
#endif
		texels[k] = texel * 255.0f;
	}
	OutBuffer[blockID] = encode_block(texels);
}

