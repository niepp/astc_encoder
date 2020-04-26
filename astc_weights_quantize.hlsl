
uint quantize_weight(uint weight_quant, uint weight)
{
	//astc_assert(weight_quant <= QUANT_32);
	//astc_assert(weight <= 1024);
	return weight_quantize_table[weight_quant][weight];
}

/**
 * Project a texel to a line and quantize the result in 1 dimension.
 *
 * The line is defined by t=k*x + m. This function calculates and quantizes x
 * by projecting n=t-m onto k, x=|n|/|k|. Since k and m is derived from the
 * minimum and maximum of all texel values the result will be in the range [0,
 * 1].
 *
 * To quantize the result using the weight_quantize_table the value needs to
 * be extended to the range [0, 1024].
 *
 * @param k the derivative of the line
 * @param m the minimum endpoint
 * @param t the texel value
 */
uint project_scaler(uint k, uint m, uint t)
{
	//astc_assert(k > 0);
	return (uint)((t - m) * 1024) / k;
}

/**
 * Project a texel to a line and quantize the result in 3 dimensions.
 */
uint project(int3 k, int3 m, int3 t)
{
	int len = dot(k, k);
	int proj = dot(t - m, k) * 1024 / len;
	return clamp(proj, 0, 1024);
}

float get_bilinear_weight(int p, float start, float end)
{
	float w = 1.0f;
	if (p < start)
	{
		w = p + 1 - start;
	}
	else if (p + 1 >= end)
	{
		w = end - p;
	}
	return w;
}

void calculate_quantized_weights_rgb(uint4 texels[BLOCK_SIZE],
	uint quant,
	int3 e0,
	int3 e1,
	out uint weights[BLOCK_SIZE],
	uint x_grids, uint y_grids)
{
	uint weight_count = x_grids * y_grids;
	uint3 de = e0 - e1;
	uint d = dot(de, de);
	if (d == 0)
	{
		for (uint i = 0; i < weight_count; ++i)
		{
			weights[i] = 0;  // quantize_weight(quant, 0) is always 0
		}
	}
	else
	{
		int3 k = e1 - e0;
		int3 m = e0;

		float x_step = 1.0f * BLOCK_SIZE_X / x_grids;
		float y_step = 1.0f * BLOCK_SIZE_Y / y_grids;

		//for (uint i = 0; i < x_grids; ++i)
		//{
		//	for (uint j = 0; j < y_grids; ++j)
		//	{
		//		float x_start = i * x_step;
		//		float x_end = (i + 1) * x_step;
		//		uint x_start_idx = (uint)(x_start);
		//		uint x_end_idx = (uint)(x_end);

		//		float y_start = j * y_step;
		//		float y_end = (j + 1) * y_step;
		//		uint y_start_idx = (uint)(y_start);
		//		uint y_end_idx = (uint)(y_end);

		//		float sum_w = 0;
		//		float wx = 0;
		//		float wy = 0;
		//		float3 sum_tex = {0, 0, 0};

		//		for (uint bx = x_start_idx; bx <= x_end_idx; ++bx)
		//		{
		//			for (uint by = y_start_idx; by <= y_end_idx; ++by)
		//			{
		//				wx = clamp(get_bilinear_weight(bx, x_start, x_end), 0, 1.0);
		//				wy = clamp(get_bilinear_weight(by, y_start, y_end), 0, 1.0);
		//				sum_w += wx * wy;

		//				uint bidx = bx + by * BLOCK_SIZE_X;
		//				sum_tex = sum_tex + to_float3(texels[bidx].xyz) * wx * wy;
		//			}
		//		}

		//		sum_tex = sum_tex / sum_w;
		//		//weights[i + j * x_grids] = quantize_weight(quant, project(k, m, to_int3(sum_tex)));

		//		weights[i + j * x_grids] = quantize_weight(quant, project(k, m, texels[i + j * x_grids].xyz));
		//	}
		//}

		for (uint i = 0; i < BLOCK_SIZE; ++i)
		{
			weights[i] = quantize_weight(quant, project(k, m, texels[i].xyz));
		}

	}
}
