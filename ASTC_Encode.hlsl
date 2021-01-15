

int InTexelHeight;
int InGroupNumX;

Texture2D InTexture;
RWStructuredBuffer<uint4> OutBuffer;

#define THREAD_NUM_X 8
#define THREAD_NUM_Y 8

//#include "Common.ush"

#include "ASTC_Define.hlsl"
#include "ASTC_Table.hlsl"
#include "ASTC_IntegerSequenceEncoding.hlsl"

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// calc the dominant axis
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
float4 mean(uint4 texels[BLOCK_SIZE], uint count)
{
	float4 sum = float4(0, 0, 0, 0);
	for (uint i = 0; i < count; ++i)
	{
		sum += texels[i];
	}
	return sum / count;
}

float4x4 covariance(float4 m[BLOCK_SIZE], uint count)
{
	float inv = 1.0 / (count - 1);
	float4x4 cov;
	for (uint i = 0; i < 4; ++i)
	{
		for (uint j = 0; j < 4; ++j)
		{
			float s = 0;
			for (uint k = 0; k < count; ++k)
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
	for (uint i = 0; i < 8; ++i)
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

void principal_component_analysis(uint4 texels[BLOCK_SIZE], uint count, out float4 e0, out float4 e1, out float dots[16])
{
	float4 pt_mean = mean(texels, count);

	float4 sub[BLOCK_SIZE];
	uint i = 0;
	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		sub[i] = texels[i] - pt_mean;
	}

	float4x4 cov = covariance(sub, count);

	float4 vec_k = eigen_vector(cov);

	// if the direction-vector ends up pointing from light to dark, FLIP IT!
	// this will make the first endpoint the darkest one.
	if (vec_k.x + vec_k.y + vec_k.z < 0.0f)
	{
		vec_k = -vec_k;
	}

	float a = 1e31;
	float b = -1e31;
	for (i = 0; i < count; ++i)
	{
		float t = dot(sub[i], vec_k);
		a = min(a, t);
		b = max(b, t);
		dots[i] = (t + 10.0) * 10.0;
	}

	e0 = clamp(vec_k * a + pt_mean, 0.0, 255.0);
	e1 = clamp(vec_k * b + pt_mean, 0.0, 255.0);

	//e0 = frac(pt_mean) * 100;
	//e1 = vec_k * 100;

}


//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// quantize & unquantize the endpoints
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
uint3 quantize_rgb(uint quantmethod, uint3 c)
{
	uint3 result;
	uint qm = quant_method_map[quantmethod];
	result.r = color_quantize_table[qm][c.r];
	result.g = color_quantize_table[qm][c.g];
	result.b = color_quantize_table[qm][c.b];
	return result;
}

uint3 unquantize_rgb(uint quantmethod, uint3 c)
{
	uint3 result;
	uint qm = quant_method_map[quantmethod];
	result.r = color_unquantize_table[qm][c.r];
	result.g = color_unquantize_table[qm][c.g];
	result.b = color_unquantize_table[qm][c.b];
	return result;
}

uint4 quantize_rgba(uint quantmethod, uint4 c)
{
	uint4 result;
	uint qm = quant_method_map[quantmethod];
	result.rgb = quantize_rgb(quantmethod, c.rgb);
	result.a = color_quantize_table[qm][c.a];
	return result;
}

uint4 unquantize_rgba(uint quantmethod, uint4 c)
{
	uint4 result;
	uint qm = quant_method_map[quantmethod];
	result.rgb = unquantize_rgb(quantmethod, c.rgb);
	result.a = color_unquantize_table[qm][c.a];
	return result;
}

void encode_rgb(uint quantmethod, float3 e0, float3 e1, out uint endpoint_quantized[6])
{
	uint3 e0q = quantize_rgb(quantmethod, round(e0));
	uint3 e1q = quantize_rgb(quantmethod, round(e1));

	uint3 e0u = unquantize_rgb(quantmethod, e0q);
	uint3 e1u = unquantize_rgb(quantmethod, e1q);

	// Sort the endpoints to ensure that the normal encoding is used.
	if (sum(e0u) > sum(e1u))
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

void decode_rgb(uint quantmethod, uint endpoint_quantized[6], out float4 e0, out float4 e1)
{
	uint qm = quant_method_map[quantmethod];
	int ir0 = color_unquantize_table[qm][endpoint_quantized[0]];
	int ir1 = color_unquantize_table[qm][endpoint_quantized[1]];
	int ig0 = color_unquantize_table[qm][endpoint_quantized[2]];
	int ig1 = color_unquantize_table[qm][endpoint_quantized[3]];
	int ib0 = color_unquantize_table[qm][endpoint_quantized[4]];
	int ib1 = color_unquantize_table[qm][endpoint_quantized[5]];

	if (ir0 + ig0 + ib0 > ir1 + ig1 + ib1)
	{
		e0 = float4(ir1, ig1, ib1, 255);
		e1 = float4(ir0, ig0, ib0, 255);
	}
	else
	{
		e0 = float4(ir0, ig0, ib0, 255);
		e1 = float4(ir1, ig1, ib1, 255);
	}
}

void encode_rgba(uint quantmethod, float4 e0, float4 e1, out uint endpoint_quantized[8])
{
	uint4 e0q = quantize_rgba(quantmethod, round(e0));
	uint4 e1q = quantize_rgba(quantmethod, round(e1));

	uint4 e0u = unquantize_rgba(quantmethod, e0q);
	uint4 e1u = unquantize_rgba(quantmethod, e1q);

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

void decode_rgba(uint quantmethod, uint endpoint_quantized[8], out float4 e0, out float4 e1)
{
	uint qm = quant_method_map[quantmethod];
	int ir0 = color_unquantize_table[qm][endpoint_quantized[0]];
	int ir1 = color_unquantize_table[qm][endpoint_quantized[1]];
	int ig0 = color_unquantize_table[qm][endpoint_quantized[2]];
	int ig1 = color_unquantize_table[qm][endpoint_quantized[3]];
	int ib0 = color_unquantize_table[qm][endpoint_quantized[4]];
	int ib1 = color_unquantize_table[qm][endpoint_quantized[5]];
	int a0 = color_unquantize_table[qm][endpoint_quantized[6]];
	int a1 = color_unquantize_table[qm][endpoint_quantized[7]];

	if (ir0 + ig0 + ib0 > ir1 + ig1 + ib1)
	{
		e0 = float4(ir1, ig1, ib1, a1);
		e1 = float4(ir0, ig0, ib0, a0);
	}
	else
	{
		e0 = float4(ir0, ig0, ib0, a0);
		e1 = float4(ir1, ig1, ib1, a1);
	}

}



//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// calculate quantized weights
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
uint quantize_weight(uint quantmethod, float weight)
{
	uint r = (weight_quantize_table[quantmethod] - 1);
	float u = clamp(weight, 0.0, 1.0) * r;
	uint q = (uint)(u + 0.5);
	return clamp(q, 0, r);
}

float unquantize_weight(uint quantmethod, uint qw)
{
	float w = 1.0 * qw / (weight_quantize_table[quantmethod] - 1);
	return clamp(w, 0.0, 1.0);
}

void calculate_quantized_weights(uint4 texels[BLOCK_SIZE],
	uint quantmethod,
	float4 ep0,
	float4 ep1,
	inout uint weights[ISE_BYTE_COUNT])
{
	float4 vec_k = ep1 - ep0;
	uint squdist = dot(vec_k, vec_k);
	if (squdist == 0)
	{
		for (uint i = 0; i < BLOCK_SIZE; ++i)
		{
			weights[i] = 0;  // quantize_weight(quant, 0) is always 0
		}
	}
	else
	{
		vec_k = normalize(vec_k);
		float minw = 1e31;
		float maxw = -1e31;
		float projw[BLOCK_SIZE];
		uint i = 0;
		for (i = 0; i < BLOCK_SIZE; ++i)
		{
			projw[i] = dot(vec_k, texels[i] - ep0);
			minw = min(projw[i], minw);
			maxw = max(projw[i], maxw);
		}

		float len = maxw - minw;
		len = max(SMALL_VALUE, len);
		float invlen = 1.0 / len;
		for (i = 0; i < BLOCK_SIZE; ++i)
		{
			weights[i] = quantize_weight(quantmethod, (projw[i] - minw) * invlen);
		}
	}
}

void lerp_colors_by_weights(uint weights_quantized[ISE_BYTE_COUNT], uint quantmethod, float4 ep0, float4 ep1, out float4 decode_texels[BLOCK_SIZE])
{
	for (int i = 0; i < BLOCK_SIZE; ++i)
	{
		float w = unquantize_weight(quantmethod, weights_quantized[i]);
		decode_texels[i] = lerp(ep0, ep1, w);
	}
}



//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// encode single partition
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

void choose_best_quantmethod(uint4 texels[BLOCK_SIZE], float4 ep0, float4 ep1, uint hasalpha, out uint best_wt_quant, out uint best_ep_quant)
{
	float minerr = 1e31;
	if (hasalpha > 0)
	{
		for (int k = 0; k < BLOCK_MODE_NUM; ++k)
		{
			// encode
			uint wq_level = block_modes[1][k][0];
			uint cq_level = block_modes[1][k][1];
			uint endpoints_quantized[8];
			uint weights_quantized[ISE_BYTE_COUNT];
			uint i = 0;
			for (i = 0; i < ISE_BYTE_COUNT; ++i)
			{
				weights_quantized[i] = 0;
			}
			encode_rgba(cq_level, ep0, ep1, endpoints_quantized);
			calculate_quantized_weights(texels, wq_level, ep0, ep1, weights_quantized);

			// decode
			float4 decode_ep0 = 0;
			float4 decode_ep1 = 0;
			decode_rgba(cq_level, endpoints_quantized, decode_ep0, decode_ep1);
			float4 decode_texels[BLOCK_SIZE];
			lerp_colors_by_weights(weights_quantized, wq_level, decode_ep0, decode_ep1, decode_texels);

			// compare the decode texels and origin
			float sum = 0;
			for (i = 0; i < BLOCK_SIZE; ++i)
			{
				float4 diff = texels[i] - decode_texels[i];
				float squlen = dot(diff, diff);
				sum += squlen;
			}

			if (sum < minerr)
			{
				minerr = sum;
				best_wt_quant = wq_level;
				best_ep_quant = cq_level;
			}

		}
	}
	else
	{
		for (int k = 0; k < BLOCK_MODE_NUM; ++k)
		{
			// encode
			uint wq_level = block_modes[0][k][0];
			uint cq_level = block_modes[0][k][1];
			uint endpoints_quantized[6];
			uint weights_quantized[ISE_BYTE_COUNT];
			uint i = 0;
			for (i = 0; i < ISE_BYTE_COUNT; ++i)
			{
				weights_quantized[i] = 0;
			}
			encode_rgb(cq_level, ep0.rgb, ep1.rgb, endpoints_quantized);
			calculate_quantized_weights(texels, wq_level, ep0, ep1, weights_quantized);

			// decode
			float4 decode_ep0 = 0;
			float4 decode_ep1 = 0;
			decode_rgb(cq_level, endpoints_quantized, decode_ep0, decode_ep1);
			float4 decode_texels[BLOCK_SIZE];
			lerp_colors_by_weights(weights_quantized, wq_level, decode_ep0, decode_ep1, decode_texels);

			// compare the decode texels and origin
			float sum = 0;
			for (i = 0; i < BLOCK_SIZE; ++i)
			{
				float4 diff = texels[i] - decode_texels[i];
				float squlen = dot(diff, diff);
				sum += squlen;
			}

			if (sum < minerr)
			{
				minerr = sum;
				best_wt_quant = wq_level;
				best_ep_quant = cq_level;
			}

		}

	}
}

uint4 assemble_block(uint blockmode, uint color_endpoint_mode, uint partition_count, uint partition_index, uint4 ep_ise, uint ep_bitcnt, uint4 wt_ise, uint wt_bitcnt)
{

	uint weights[16];
	uint4_2_array16(wt_ise, weights);

	uint i = 0;
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

	for (i = 0; i < BLOCK_BYTES - MAX_ENCODED_WEIGHT_BYTES; ++i)
	{
		weights[i] = 0;
	}

	uint4 phy_blk = array16_2_uint4(weights);
	phy_blk = orbits8_ptr(phy_blk, 0, blockmode & 0xFF, 8);
	phy_blk = orbits8_ptr(phy_blk, 8, (blockmode >> 8) & 0xFF, 3);

	uint multi = partition_count > 1 ? 1 : 0;

	uint part_value = partition_count - 1;
	uint part_index = multi * partition_index;
	phy_blk = orbits8_ptr(phy_blk, 11, part_value, 2);

	if (partition_count > 1)
	{
		phy_blk = orbits8_ptr(phy_blk, 13, part_index & 63, 6);
		phy_blk = orbits8_ptr(phy_blk, 19, part_index >> 6, 4);
	}

	// CEM	
	uint cem_offset = multi * 10 + 13;
	uint endpoint_offset = multi * 12 + 17;
	uint cem_bits = multi * 2 + 4;

	phy_blk = orbits8_ptr(phy_blk, cem_offset, color_endpoint_mode, cem_bits);

	// endpoints start from ( multi_part ? bits 29 : bits 17 )
	copy_bytes(ep_ise, MAX_ENCODED_COLOR_ENDPOINT_BYTES, phy_blk, endpoint_offset);

	return phy_blk;

}

uint4 encode_single_partition(uint4 texels[BLOCK_SIZE], uint count, uint hasalpha)
{
	float dots[16];
	float4 ep0, ep1;
	principal_component_analysis(texels, count, ep0, ep1, dots);

	// for single partition
	uint partition_index = 0;
	uint partition_count = 1;

	uint x_grids = 4;
	uint y_grids = 4;

	uint weights_count = x_grids * y_grids; // weights count equal to pixels count

/*
	the first row of "Table C.2.8 - 2D Block Mode Layout".
	------------------------------------------------------------------------
	10  9   8   7   6   5   4   3   2   1   0   Width Height Notes
	------------------------------------------------------------------------
	D   H     B       A     R0  0   0   R2  R1  B + 4   A + 2
*/

	uint a = y_grids - 2;
	uint b = x_grids - 4;

	a &= 0x3;
	b &= 0x3;

	uint d = 0;  // dual plane

	// endpoints_quant是根据整个128bits减去weights的编码占用和其他配置占用后剩余的bits位数来确定的。
	uint weight_quantmethod = QUANT_8;
	uint endpoint_quantmethod = QUANT_256;
	uint color_endpoint_mode = (hasalpha > 0) ? CEM_LDR_RGBA_DIRECT : CEM_LDR_RGB_DIRECT;

	choose_best_quantmethod(texels, ep0, ep1, hasalpha, weight_quantmethod, endpoint_quantmethod);

	// reference from arm astc encoder "symbolic_to_physical"
	uint bytes_of_one_endpoint = 2 * (color_endpoint_mode >> 2) + 2;

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
	uint blockmode = (r >> 1) & 0x3;
	blockmode |= (r & 0x1) << 4;
	blockmode |= (a & 0x3) << 5;
	blockmode |= (b & 0x3) << 7;
	blockmode |= h << 9;
	blockmode |= d << 10;

	uint endpoints_quantized[ISE_BYTE_COUNT];
	uint i = 0;
	for (i = 0; i < ISE_BYTE_COUNT; ++i)
	{
		endpoints_quantized[i] = 0;
	}

	// encode endpoints
	if (hasalpha > 0)
	{
		uint ep_quantized[8];
		encode_rgba(endpoint_quantmethod, ep0, ep1, ep_quantized);
		for (i = 0; i < 8; ++i)
		{
			endpoints_quantized[i] = ep_quantized[i];
		}
	}
	else
	{
		uint ep_quantized[6];
		encode_rgb(endpoint_quantmethod, ep0.rgb, ep1.rgb, ep_quantized);
		for (i = 0; i < 6; ++i)
		{
			endpoints_quantized[i] = ep_quantized[i];
		}
	}

	// encode weights
	uint weights_quantized[ISE_BYTE_COUNT];
	for (i = 0; i < ISE_BYTE_COUNT; ++i)
	{
		weights_quantized[i] = 0;
	}
	calculate_quantized_weights(texels, weight_quantmethod, ep0, ep1, weights_quantized);

	for (i = 0; i < BLOCK_SIZE; ++i)
	{
		weights_quantized[i] = scramble_table[weight_quantmethod][weights_quantized[i]];
	}

	// endpoints_quantized ise encode
	uint4 ep_ise;
	uint ep_bitcnt = 0;
	uint ep_bytecnt = (hasalpha > 0) ? 8 : 6;
	integer_sequence_encode(endpoints_quantized, ep_bytecnt, endpoint_quantmethod, ep_ise, ep_bitcnt);

	// weights_quantized ise encode
	uint4 wt_ise;
	uint wt_bitcnt = 0;
	integer_sequence_encode(weights_quantized, weights_count, weight_quantmethod, wt_ise, wt_bitcnt);

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

	uint hasalpha = 0;
	uint4 phy_blk = encode_single_partition(texels, BLOCK_SIZE, hasalpha);

	uint blockID = blockPos.y * InGroupNumX * THREAD_NUM_X + blockPos.x;
	OutBuffer[blockID] = phy_blk;

}

