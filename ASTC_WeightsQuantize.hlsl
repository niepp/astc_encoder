
uint quantize_weight(uint weight_quant, uint weight)
{
	//astc_assert(weight_quant <= QUANT_32);
	//astc_assert(weight <= 1024);
	return weight_quantize_table[weight];
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
		for (uint i = 0; i < BLOCK_SIZE; ++i)
		{
			weights[i] = quantize_weight(quant, project(k, m, texels[i].xyz));
		}

	}
}

///////////////////////////

