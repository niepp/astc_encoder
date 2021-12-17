#ifndef MAX_MIPSNUM
#define MAX_MIPSNUM 14
#endif

#ifndef THREAD_NUM_X
#define THREAD_NUM_X 8
#endif

#ifndef THREAD_NUM_Y
#define THREAD_NUM_Y 8
#endif

uint InTexelHeight;
uint InTexelWidth;
uint InGroupNumX;

//int InMipsNum;
//uint4 InBlockNums[MAX_MIPSNUM]; // ParameterType should ALIGNMENT to 16 byte，or else the API "SetShaderValueArray" failed to transfer data to shader

Texture2D InTexture;
RWStructuredBuffer<uint4> OutBuffer;

//#include "Common.ush"
//#include "GammaCorrectionCommon.ush"

#include "ASTC_Define.hlsl"
#include "ASTC_Table.hlsl"
#include "ASTC_IntegerSequenceEncoding.hlsl"

half LinearToSrgbBranchingChannel(half lin) 
{
	if(lin < 0.00313067) 
		return lin * 12.92;
	return pow(lin, (1.0/2.4)) * 1.055 - 0.055;
}

half4 get_texel(uint3 blockPos, uint idx)
{
	uint y = idx / DIM;
	uint x = idx - y * DIM;
	uint3 pixelPos = blockPos + uint3(x, y, 0);

	pixelPos.y = InTexelHeight - 1 - pixelPos.y;

	half4 texel = InTexture.Load(pixelPos);

#if IS_NORMALMAP
	texel.b = 1.0f;
	texel.a = 1.0f;
#endif

#if USE_SRGB
	//texel.rgb = LinearToSrgb(texel.rgb);
	texel.r = LinearToSrgbBranchingChannel(texel.r);
	texel.g = LinearToSrgbBranchingChannel(texel.g);
	texel.b = LinearToSrgbBranchingChannel(texel.b);
#endif
	return texel * 255.0;
}

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// calc the dominant axis
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
half4 eigen_vector(half4x4 m)
{
	// calc the max eigen value by iteration
	half4 v = half4(0.26726, 0.80178, 0.53452, 0);
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

void find_min_max(uint3 blockPos, half4 pt_mean, half4 vec_k, out half4 e0, out half4 e1)
{
	half a = 1e31;
	half b = -1e31;
	for (int i = 0; i < BLOCK_SIZE; ++i)
	{
		half4 texel = get_texel(blockPos, i);
		texel -= pt_mean;
		half t = dot(texel, vec_k);
		a = min(a, t);
		b = max(b, t);
	}

	e0 = clamp(vec_k * a + pt_mean, 0.0, 255.0);
	e1 = clamp(vec_k * b + pt_mean, 0.0, 255.0);

	// if the direction-vector ends up pointing from light to dark, FLIP IT!
	// this will make the first endpoint the darkest one.
	half4 e0u = round(e0);
	half4 e1u = round(e1);
	if (e0u.x + e0u.y + e0u.z > e1u.x + e1u.y + e1u.z)
	{
		swap(e0, e1);
	}

#if !HAS_ALPHA
	e0.a = 255.0;
	e1.a = 255.0;
#endif

}

void principal_component_analysis(uint3 blockPos, out half4 e0, out half4 e1)
{
	int i = 0;
	half4 pt_mean = 0;
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		half4 texel = get_texel(blockPos, i);
		pt_mean += texel;
	}
	pt_mean /= BLOCK_SIZE;

	half4x4 cov = 0;
	half s = 0;
	for (int k = 0; k < BLOCK_SIZE; ++k)
	{
		half4 texel = get_texel(blockPos, k);
		texel -= pt_mean;
		for (i = 0; i < 4; ++i)
		{
			for (int j = 0; j < 4; ++j)
			{
				cov[i][j] += texel[i] * texel[j];
			}
		}
	}
	cov /= BLOCK_SIZE - 1;

	half4 vec_k = eigen_vector(cov);

	find_min_max(blockPos, pt_mean, vec_k, e0, e1);

}

void max_accumulation_pixel_direction(uint3 blockPos, out half4 e0, out half4 e1)
{
	int i = 0;
	half4 pt_mean = 0;
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		half4 texel = get_texel(blockPos, i);
		pt_mean += texel;
	}
	pt_mean /= BLOCK_SIZE;

	half4 sum_r = half4(0,0,0,0);
	half4 sum_g = half4(0,0,0,0);
	half4 sum_b = half4(0,0,0,0);
	half4 sum_a = half4(0,0,0,0);
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		half4 texel = get_texel(blockPos, i);
		half4 dt = texel - pt_mean;
		sum_r += (dt.x > 0) ? dt : 0;
		sum_g += (dt.y > 0) ? dt : 0;
		sum_b += (dt.z > 0) ? dt : 0;
		sum_a += (dt.w > 0) ? dt : 0;
	}

	half dot_r = dot(sum_r, sum_r);
	half dot_g = dot(sum_g, sum_g);
	half dot_b = dot(sum_b, sum_b);
	half dot_a = dot(sum_a, sum_a);

	half maxdot = dot_r;
	half4 vec_k = sum_r;

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
	half lenk = length(vec_k);
	vec_k = (lenk < SMALL_VALUE) ? vec_k : normalize(vec_k);

	find_min_max(blockPos, pt_mean, vec_k, e0, e1);

}

/*
void bounding_box(uint3 blockPos, out half4 e0, out half4 e1)
{
	int i = 0;
	half4 pt_mean = 0;
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		half4 texel = get_texel(blockPos, i);
		pt_mean += texel;
	}
	pt_mean /= BLOCK_SIZE;

	half4 a = half4(255, 255, 255, 255);
	half4 b = half4(0, 0, 0, 0);
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		half4 texel = get_texel(blockPos, i);
		a = min(a, texel);
		b = max(b, texel);
	}

	half4 vec_k = b - a;
	// safe normalize
	half lenk = length(vec_k);
	vec_k = (lenk < SMALL_VALUE) ? vec_k : normalize(vec_k);

	find_min_max(blockPos, pt_mean, vec_k, e0, e1);

}

void max_dist_pair(uint3 blockPos, out half4 e0, out half4 e1)
{
	int i = 0;
	half4 pt_mean = 0;
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		half4 texel = get_texel(blockPos, i);
		pt_mean += texel;
	}
	pt_mean /= BLOCK_SIZE;

	half maxd = 0;
	half4 a = half4(255, 255, 255, 255);
	half4 b = half4(0, 0, 0, 0);
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		half4 texel_i = get_texel(blockPos, i);
		for (int j = i + 1; j < BLOCK_SIZE; ++j)
		{
			half4 texel_j = get_texel(blockPos, j);
			half sdist = length(texel_i - texel_j);
			if (sdist > maxd)
			{
				maxd = sdist;
				a = texel_i;
				b = texel_j;
			}
		}
	}

	half4 vec_k = b - a;
	// safe normalize
	half lenk = length(vec_k);
	vec_k = (lenk < SMALL_VALUE) ? vec_k : normalize(vec_k);

	find_min_max(blockPos, pt_mean, vec_k, e0, e1);

}
*/

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// quantize & unquantize the endpoints
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#if !FAST
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


void encode_color(uint qm_index, half4 e0, half4 e1, out uint endpoint_quantized[8])
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

void decode_color(uint qm_index, uint endpoint_quantized[8], out half4 e0, out half4 e1)
{
	uint ir0 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[0]];
	uint ir1 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[1]];
	uint ig0 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[2]];
	uint ig1 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[3]];
	uint ib0 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[4]];
	uint ib1 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[5]];
	uint a0 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[6]];
	uint a1 = color_unquantize_table[qm_index * COLOR_QUANTIZE_NUM + endpoint_quantized[7]];

	e0 = half4(ir0, ig0, ib0, a0);
	e1 = half4(ir1, ig1, ib1, a1);

	if (ir0 + ig0 + ib0 > ir1 + ig1 + ib1)
	{
		swap(e0, e1);
	}

}
#else // for QUANT_256 quantization
void encode_color(uint qm_index, half4 e0, half4 e1, out uint endpoint_quantized[8])
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

void decode_color(uint qm_index, uint endpoint_quantized[8], out half4 e0, out half4 e1)
{
	e0 = half4(endpoint_quantized[0], endpoint_quantized[2], endpoint_quantized[4], endpoint_quantized[6]);
	e1 = half4(endpoint_quantized[1], endpoint_quantized[3], endpoint_quantized[5], endpoint_quantized[7]);
}

#endif


//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// calculate quantized weights
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
uint quantize_weight(uint weight_range, half weight)
{
	uint q = round(weight * weight_range);
	return clamp(q, 0, weight_range);
}

half unquantize_weight(uint weight_range, uint qw)
{
	half w = 1.0 * qw / weight_range;
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

static const half4 wt_grids[16] = {
	half4(0.444, 0.222, 0.222, 0.111),
	half4(0.222, 0.444, 0.111, 0.222),
	half4(0.444, 0.222, 0.222, 0.111),
	half4(0.222, 0.444, 0.111, 0.222),
	half4(0.222, 0.111, 0.444, 0.222),
	half4(0.111, 0.222, 0.222, 0.444),
	half4(0.222, 0.111, 0.444, 0.222),
	half4(0.111, 0.222, 0.222, 0.444),
	half4(0.444, 0.222, 0.222, 0.111),
	half4(0.222, 0.444, 0.111, 0.222),
	half4(0.444, 0.222, 0.222, 0.111),
	half4(0.222, 0.444, 0.111, 0.222),
	half4(0.222, 0.111, 0.444, 0.222),
	half4(0.111, 0.222, 0.222, 0.444),
	half4(0.222, 0.111, 0.444, 0.222),
	half4(0.111, 0.222, 0.222, 0.444),
};


half4 sample_texel(uint3 blockPos, uint4 index, half4 coff)
{
	half4 sum = get_texel(blockPos, index.x) * coff.x;
	sum += get_texel(blockPos, index.y) * coff.y;
	sum += get_texel(blockPos, index.z) * coff.z;
	sum += get_texel(blockPos, index.w) * coff.w;
	return sum;
}

void calculate_quantized_weights(uint3 blockPos,
	uint weight_range,
	half4 ep0,
	half4 ep1,
	out uint weights[X_GRIDS * Y_GRIDS])
{
	int i = 0;
	half4 vec_k = ep1 - ep0;
	if (length(vec_k) < SMALL_VALUE)
	{
		for (i = 0; i < X_GRIDS * Y_GRIDS; ++i)
		{
			weights[i] = 0;
		}
	}
	else
	{
		vec_k = normalize(vec_k);
		half minw = 1e31f;
		half maxw = -1e31f;
		half projw[X_GRIDS * Y_GRIDS];
#if BLOCK_6X6

/* bilinear interpolation: GirdSize is 4，BlockSize is 6

	0     1     2     3     4     5
|-----|-----|-----|-----|-----|-----|
|--------|--------|--------|--------|
    0        1        2        3
*/
		for (i = 0; i < X_GRIDS * Y_GRIDS; ++i)
		{
			half4 sum = sample_texel(blockPos, idx_grids[i], wt_grids[i]);
			half w = dot(vec_k, sum - ep0);
			minw = min(w, minw);
			maxw = max(w, maxw);
			projw[i] = w;
		}
#else
		// ensure "X_GRIDS * Y_GRIDS == BLOCK_SIZE"
		for (i = 0; i < BLOCK_SIZE; ++i)
		{
			half4 texel = get_texel(blockPos, i);
			half w = dot(vec_k, texel - ep0);
			minw = min(w, minw);
			maxw = max(w, maxw);
			projw[i] = w;
		}
#endif

		half invlen = maxw - minw;
		invlen = max(SMALL_VALUE, invlen);
		invlen = 1.0 / invlen;
		for (i = 0; i < X_GRIDS * Y_GRIDS; ++i)
		{
			projw[i] = (projw[i] - minw) * invlen;
			weights[i] = quantize_weight(weight_range, projw[i]);
		}
	}
}

#if !FAST
half4 sample_texel(half4 texels[BLOCK_SIZE], uint4 index, half4 coff)
{
	half4 sum = texels[index.x] * coff.x;
	sum += texels[index.y] * coff.y;
	sum += texels[index.z] * coff.z;
	sum += texels[index.w] * coff.w;
	return sum;
}

void calculate_quantized_texelsweights(half4 texels[BLOCK_SIZE],
	uint weight_range,
	half4 ep0,
	half4 ep1,
	inout uint weights[X_GRIDS * Y_GRIDS])
{
	int i = 0;
	half4 vec_k = ep1 - ep0;
	if (length(vec_k) < SMALL_VALUE)
	{
		for (i = 0; i < X_GRIDS * Y_GRIDS; ++i)
		{
			weights[i] = 0;
		}
	}
	else
	{
		vec_k = normalize(vec_k);
		half minw = 1e31f;
		half maxw = -1e31f;
		half projw[X_GRIDS * Y_GRIDS];
#if BLOCK_6X6
		for (i = 0; i < X_GRIDS * Y_GRIDS; ++i)
		{
			half4 sum = sample_texel(texels, idx_grids[i], wt_grids[i]);
			half w = dot(vec_k, sum - ep0);
			minw = min(w, minw);
			maxw = max(w, maxw);
			projw[i] = w;
		}
#else
		for (i = 0; i < BLOCK_SIZE; ++i)
		{
			half w = dot(vec_k, texels[i] - ep0);
			minw = min(w, minw);
			maxw = max(w, maxw);
			projw[i] = w;
		}
#endif

		half invlen = maxw - minw;
		invlen = max(SMALL_VALUE, invlen);
		invlen = 1.0 / invlen;
		for (i = 0; i < X_GRIDS * Y_GRIDS; ++i)
		{
			projw[i] = (projw[i] - minw) * invlen;
			weights[i] = quantize_weight(weight_range, projw[i]);
		}
	}
}

static const half2 wt_lerp[6] = {
	half2(1.0f, 0.0f),
	half2(0.5f, 0.5f),
	half2(1.0f, 0.0f),
	half2(1.0f, 0.0f),
	half2(0.5f, 0.5f),
	half2(1.0f, 0.0f),
};

static const uint2 indexmap_lerp[6] = {
	uint2(0, 0),
	uint2(0, 1),
	uint2(1, 1),
	uint2(2, 2),
	uint2(2, 3),
	uint2(3, 3),
};

half sumdiff_of_lerp_colors(half4 texels[BLOCK_SIZE], uint weights_quantized[X_GRIDS * Y_GRIDS], uint weight_range, half4 ep0, half4 ep1)
{
	half sumdiff = 0;
#if BLOCK_6X6
	for (int i = 0; i < BLOCK_SIZE; ++i)
	{
		uint idx = i;
		int row = idx / DIM;
		int col = idx % DIM;

		half wr0 = wt_lerp[row].x;
		half wr1 = wt_lerp[row].y;
		half wc0 = wt_lerp[col].x;
		half wc1 = wt_lerp[col].y;

		int y0 = indexmap_lerp[row].x;
		int y1 = indexmap_lerp[row].y;
		int x0 = indexmap_lerp[col].x;
		int x1 = indexmap_lerp[col].y;

		uint wq00 = weights_quantized[y0 * X_GRIDS + x0];
		uint wq01 = weights_quantized[y0 * X_GRIDS + x1];
		uint wq10 = weights_quantized[y1 * X_GRIDS + x0];
		uint wq11 = weights_quantized[y1 * X_GRIDS + x1];

		half4 wuq;
		wuq.x = unquantize_weight(weight_range, wq00);
		wuq.y = unquantize_weight(weight_range, wq01);
		wuq.z = unquantize_weight(weight_range, wq10);
		wuq.w = unquantize_weight(weight_range, wq11);

		half4 diff = half4(wr0 * wc0, wr0 * wc1, wr1 * wc0, wr1 * wc1);
		half w = dot(diff, wuq);
		diff = lerp(ep0, ep1, w);
		diff -= texels[i];
		sumdiff += dot(diff, diff);
	}
#else
	for (int i = 0; i < BLOCK_SIZE; ++i)
	{
		half w = unquantize_weight(weight_range, weights_quantized[i]);
		half4 diff = lerp(ep0, ep1, w);
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

void choose_best_quantmethod(uint3 blockPos, half4 ep0, half4 ep1, out uint4 best_blockmode)
{
	half minerr = 1e31;
	int k = 0;
	half4 texels[BLOCK_SIZE];
	for (k = 0; k < BLOCK_SIZE; ++k)
	{
		texels[k] = get_texel(blockPos, k);
	}

	for (k = 0; k < BLOCK_MODE_NUM; ++k)
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
		calculate_quantized_texelsweights(texels, blockmode.z - 1, ep0, ep1, weights_quantized);

		// decode
		half4 decode_ep0 = 0;
		half4 decode_ep1 = 0;
		decode_color(blockmode.w, endpoints_quantized, decode_ep0, decode_ep1);
		half sum = sumdiff_of_lerp_colors(texels, weights_quantized, blockmode.z - 1, decode_ep0, decode_ep1);
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

uint4 endpoint_ise(uint colorquant_index, half4 ep0, half4 ep1, uint endpoint_quantmethod)
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

uint4 weight_ise(uint3 blockPos, uint weight_range, half4 ep0, half4 ep1, uint  weight_quantmethod)
{
	int i = 0;
	// encode weights
	uint wt_quantized[X_GRIDS * Y_GRIDS];
	calculate_quantized_weights(blockPos, weight_range, ep0, ep1, wt_quantized);

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

uint4 encode_block(uint3 blockPos)
{
	half4 ep0, ep1;
	//principal_component_analysis(blockPos, ep0, ep1);
	max_accumulation_pixel_direction(blockPos, ep0, ep1);

//	return round((ep0 + ep1) * 0.5f);

	// endpoints_quant是根据整个128bits减去weights的编码占用和其他配置占用后剩余的bits位数来确定的。
	// for fast compression!
#if HAS_ALPHA
	uint4 best_blockmode = uint4(QUANT_6, QUANT_256, 6, 7);
#else
	uint4 best_blockmode = uint4(QUANT_12, QUANT_256, 12, 7);
#endif

#if !FAST
	choose_best_quantmethod(blockPos, ep0, ep1, best_blockmode);
#endif

	//uint weight_quantmethod = best_blockmode.x;
	//uint endpoint_quantmethod = best_blockmode.y;
	//uint weight_range = best_blockmode.z;
	//uint colorquant_index = best_blockmode.w;

	// reference from arm astc encoder "symbolic_to_physical"
	//uint bytes_of_one_endpoint = 2 * (color_endpoint_mode >> 2) + 2;

	uint blockmode = assemble_blockmode(best_blockmode.x);

	uint4 ep_ise = endpoint_ise(best_blockmode.w, ep0, ep1, best_blockmode.y);

	uint4 wt_ise = weight_ise(blockPos, best_blockmode.z - 1, ep0, ep1, best_blockmode.x);

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
	int mipLevel = 0;
	uint blockID = DTid.y * InGroupNumX * THREAD_NUM_X + DTid.x;
	/*
	int i = 1;
	for (i = 1; i <= InMipsNum; ++i)
	{
		if (blockID < InBlockNums[i].x) // InBlockNums[0] is always 0
		{
			mipLevel = i - 1;
			break;
		}
	}
	*/

	uint2 BlockNum;
	BlockNum.x = ((InTexelWidth >> mipLevel) + DIM - 1) / DIM;
	BlockNum.y = ((InTexelHeight >> mipLevel) + DIM - 1) / DIM;

	uint3 blockPos;
	blockPos.y = (uint)(blockID / BlockNum.x);
	blockPos.x = blockID - blockPos.y * BlockNum.x;
	blockPos.xy *= DIM;
	blockPos.z = mipLevel;

	OutBuffer[blockID] = encode_block(blockPos);

}

