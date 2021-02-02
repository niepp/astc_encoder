 /**
  * Table that describes the number of trits or quints along with bits required
  * for storing each range.
  */
static const int bits_trits_quints_table[QUANT_MAX * 3] =
{
	1, 0, 0,  // RANGE_2
	0, 1, 0,  // RANGE_3
	2, 0, 0,  // RANGE_4
	0, 0, 1,  // RANGE_5
	1, 1, 0,  // RANGE_6
	3, 0, 0,  // RANGE_8
	1, 0, 1,  // RANGE_10
	2, 1, 0,  // RANGE_12
	4, 0, 0,  // RANGE_16
	2, 0, 1,  // RANGE_20
	3, 1, 0,  // RANGE_24
	5, 0, 0,  // RANGE_32
	3, 0, 1,  // RANGE_40
	4, 1, 0,  // RANGE_48
	6, 0, 0,  // RANGE_64
	4, 0, 1,  // RANGE_80
	5, 1, 0,  // RANGE_96
	7, 0, 0,  // RANGE_128
	5, 0, 1,  // RANGE_160
	6, 1, 0,  // RANGE_192
	8, 0, 0   // RANGE_256
};

/**
 * Compute the number of bits required to store a number of items in a specific
 * range using the bounded integer sequence encoding.
 */
int compute_ise_bitcount(int items, int range)
{
	int bits = bits_trits_quints_table[range * 3 + 0];
	int trits = bits_trits_quints_table[range * 3 + 1];
	int quints = bits_trits_quints_table[range * 3 + 2];

	if (trits)
	{
		return ((8 + 5 * bits) * items + 4) / 5;
	}

	if (quints)
	{
		return ((7 + 3 * bits) * items + 2) / 3;
	}

	return items * bits;
}

// 取第n个bit位的值
int getbit(int number, int n)
{
	return (number >> n) & 1;
}

// 取第lsb到msb的这几个bit位的值
int getbits(int number, int msb, int lsb)
{
	int count = msb - lsb + 1;
	return (number >> lsb) & ((1 << count) - 1);
}

// 把number的低bitcount位写到bytes的bitoffset偏移处开始的位置
// number must be <= 255; bitcount must be <= 8
int4 orbits8_ptr(int4 bytes, int bitoffset, int number, int bitcount)
{
	int4 retv = bytes;
	bitcount = bitcount > 8 ? 8 : bitcount;
	number &= (1 << bitcount) - 1;

	int newpos = bitoffset + bitcount;
	if (bitoffset < 32)
	{
		int lowpart = bitoffset > 0 ? number & ((1 << (32 - bitoffset)) - 1) : number;
		retv.x = bytes.x | (lowpart << bitoffset);

		int highpart = newpos > 32 ? number >> (32 - bitoffset) : 0;
		retv.y = bytes.y | highpart;
	}
	else if (bitoffset < 64)
	{
		int lowpart = bitoffset > 32 ? number & ((1 << (64 - bitoffset)) - 1) : number;
		retv.y = bytes.y | (lowpart << (bitoffset - 32));

		int highpart = newpos > 64 ? number >> (64 - bitoffset) : 0;
		retv.z = bytes.z | highpart;
	}
	else if (bitoffset < 96)
	{
		int lowpart = bitoffset > 64 ? number & ((1 << (96 - bitoffset)) - 1) : number;
		retv.z = bytes.z | (lowpart << (bitoffset - 64));

		int highpart = newpos > 96 ? number >> (96 - bitoffset) : 0;
		retv.w = bytes.w | highpart;
	}
	else
	{
		int lowpart = bitoffset > 96 ? number & ((1 << (128 - bitoffset)) - 1) : number;
		retv.w = bytes.w | (lowpart << (bitoffset - 96));
	}

	return retv;
}

void split_high_low(int n, int i, out int high, out int low)
{
	int low_mask = ((1 << i) - 1) & 0xFF;
	low = n & low_mask;
	high = (n >> i) & 0xFF;
}


/**
 * Reverse bits of a byte.
 */
int reverse_byte(int p)
{
	p = ((p & 0xF) << 4) | ((p >> 4) & 0xF);
	p = ((p & 0x33) << 2) | ((p >> 2) & 0x33);
	p = ((p & 0x55) << 1) | ((p >> 1) & 0x55);
	return p;
}


void copy_bytes(int4 source, int bytecount, inout int4 target, inout int bitoffset)
{
	int4 outbytes = target;
	int src_bytes[16];
	int4_2_array16(source, src_bytes);
	for (int i = 0; i < bytecount; ++i)
	{
		outbytes = orbits8_ptr(outbytes, bitoffset + i * 8, src_bytes[i], 8);
	}
	target = outbytes;
	bitoffset += bytecount * 8;
}

/**
 * Encode a group of 5 numbers using trits and bits.
 */
void encode_trits(int bitcount,
	int b0,
	int b1,
	int b2,
	int b3,
	int b4,
	inout int4 outputs, inout int outpos)
{
	int t0, t1, t2, t3, t4;
	int m0, m1, m2, m3, m4;

	split_high_low(b0, bitcount, t0, m0);
	split_high_low(b1, bitcount, t1, m1);
	split_high_low(b2, bitcount, t2, m2);
	split_high_low(b3, bitcount, t3, m3);
	split_high_low(b4, bitcount, t4, m4);

	int packhigh = integer_from_trits[t4][t3][t2][t1][t0];

	outputs = orbits8_ptr(outputs, outpos, m0, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packhigh, 1, 0), 2);
	outpos += 2;

	outputs = orbits8_ptr(outputs, outpos, m1, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packhigh, 3, 2), 2);
	outpos += 2;

	outputs = orbits8_ptr(outputs, outpos, m2, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packhigh, 4, 4), 1);
	outpos += 1;

	outputs = orbits8_ptr(outputs, outpos, m3, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packhigh, 6, 5), 2);
	outpos += 2;

	outputs = orbits8_ptr(outputs, outpos, m4, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packhigh, 7, 7), 1);
	outpos += 1;

}

/**
 * Encode a group of 3 numbers using quints and bits.
 */
void encode_quints(int bitcount,
	int b0,
	int b1,
	int b2,
	inout int4 outputs, inout int outpos)
{
	int q0, q1, q2;
	int m0, m1, m2;

	split_high_low(b0, bitcount, q0, m0);
	split_high_low(b1, bitcount, q1, m1);
	split_high_low(b2, bitcount, q2, m2);

	int packhigh = integer_from_quints[q2][q1][q0];

	outputs = orbits8_ptr(outputs, outpos, m0, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packhigh, 2, 0), 3);
	outpos += 3;

	outputs = orbits8_ptr(outputs, outpos, m1, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packhigh, 4, 3), 2);
	outpos += 2;

	outputs = orbits8_ptr(outputs, outpos, m2, bitcount);
	outpos += bitcount;

	outputs = orbits8_ptr(outputs, outpos, getbits(packhigh, 6, 5), 2);
	outpos += 2;

}

/**
 * Encode a sequence of numbers using using one trit and a custom number of
 * bits per number.
 */
void encode_by_trits(int numbers[ISE_BYTE_COUNT], int numcount, int bitcount, out int4 outputs, out int bitoffset)
{
	int4 outbytes = 0;
	int bitpos = 0;
	int num = (numcount + 4) - (numcount + 4) % 5;

	for (int i = 0; i < num; i += 5)
	{
		int b0 = numbers[i + 0];
		int b1 = numbers[i + 1];
		int b2 = numbers[i + 2];
		int b3 = numbers[i + 3];
		int b4 = numbers[i + 4];
		encode_trits(bitcount, b0, b1, b2, b3, b4, outbytes, bitpos);
	}
	outputs = outbytes;
	bitoffset = bitpos;
}

/**
 * Encode a sequence of numbers using one quint and the custom number of bits
 * per number.
 */
void encode_by_quints(int numbers[ISE_BYTE_COUNT], int numcount, int bitcount, out int4 outputs, out int bitoffset)
{
	int4 outbytes = 0;
	int bitpos = 0;
	int num = (numcount + 2) - (numcount + 2) % 3;

	for (int i = 0; i < num; i += 3)
	{
		int b0 = numbers[i + 0];
		int b1 = numbers[i + 1];
		int b2 = numbers[i + 2];
		encode_quints(bitcount, b0, b1, b2, outbytes, bitpos);
	}

	outputs = outbytes;
	bitoffset = bitpos;
}

/**
 * Encode a sequence of numbers using binary representation with the selected
 * bit count.
 */
inline void encode_by_binary(int numbers[ISE_BYTE_COUNT], int numcount, int bitcount, out int4 outputs, out int bitoffset)
{
	int4 outbytes = int4(0, 0, 0, 0);
	int bitpos = 0;

	for (int i = 0; i < numcount; ++i)
	{
		outbytes = orbits8_ptr(outbytes, bitpos, numbers[i], bitcount);
		bitpos += bitcount;
	}
	outputs = outbytes;
	bitoffset = bitpos;
}

void bise_endpoints(int numbers[8], int hasalpha, int range, out int4 outputs, out int bitpos)
{
	int bits = bits_trits_quints_table[range * 3 + 0];
	int trits = bits_trits_quints_table[range * 3 + 1];
	int quints = bits_trits_quints_table[range * 3 + 2];

	if (trits == 1)
	{
		outputs = 0;
		bitpos = 0;

		int b0 = numbers[0];
		int b1 = numbers[1];
		int b2 = numbers[2];
		int b3 = numbers[3];
		int b4 = numbers[4];
		encode_trits(bits, b0, b1, b2, b3, b4, outputs, bitpos);

		b0 = numbers[5];
		b1 = hasalpha ? numbers[6] : 0;
		b2 = hasalpha ? numbers[7] : 0;
		encode_trits(bits, b0, b1, b2, 0, 0, outputs, bitpos);

	}
	else if (quints == 1)
	{
		outputs = 0;
		bitpos = 0;

		int b0 = numbers[0];
		int b1 = numbers[1];
		int b2 = numbers[2];
		encode_quints(bits, b0, b1, b2, outputs, bitpos);

		b0 = numbers[3];
		b1 = numbers[4];
		b2 = numbers[5];
		encode_quints(bits, b0, b1, b2, outputs, bitpos);

		b0 = hasalpha ? numbers[6] : 0;
		b1 = hasalpha ? numbers[7] : 0;
		encode_quints(bits, b0, b1, 0, outputs, bitpos);

	}
	else
	{
		//outputs = 0;
		//bitpos = 8 * bits;
		//outputs.x = (numbers[0]) | (numbers[1] << 8) | (numbers[2] << 16) | (numbers[3] << 24);
		//outputs.y = (numbers[4]) | (numbers[5] << 8) | (numbers[6] << 16) | (numbers[7] << 24);	



		int outs[16],

		bitpos = 0;
		int i = 0;
		for (i = 0; i < 16; ++i)
		{
			outs[i] = 0;
		}
		for (i = 0; i < 8; ++i)
		{
			int idx = bitpos / 8;
			int offset = bitpos % 8;
			int mask = (numbers[i] << offset);
			outs[idx] |= mask & 0xFF;
			outs[idx + 1] |= (mask >> 8) & 0xFF;
			bitpos += bits;
		}

		outputs = array16_2_int4(outs);

	}

}

//void bise_weights(int numbers[16], int range, out int outputs[16], out int bitpos)
void bise_weights(int numbers[16], int range, out int4 outputs, out int bitpos)
{
	int bits = bits_trits_quints_table[range * 3 + 0];
	int trits = bits_trits_quints_table[range * 3 + 1];
	int quints = bits_trits_quints_table[range * 3 + 2];

	if (trits == 1)
	{
		outputs = 0;
		bitpos = 0;

		int b0 = numbers[0];
		int b1 = numbers[1];
		int b2 = numbers[2];
		int b3 = numbers[3];
		int b4 = numbers[4];
		encode_trits(bits, b0, b1, b2, b3, b4, outputs, bitpos);

		b0 = numbers[5];
		b1 = numbers[6];
		b2 = numbers[7];
		b3 = numbers[8];
		b4 = numbers[9];
		encode_trits(bits, b0, b1, b2, b3, b4, outputs, bitpos);

		b0 = numbers[10];
		b1 = numbers[11];
		b2 = numbers[12];
		b3 = numbers[13];
		b4 = numbers[14];
		encode_trits(bits, b0, b1, b2, b3, b4, outputs, bitpos);

		b0 = numbers[15];
		encode_trits(bits, b0, 0, 0, 0, 0, outputs, bitpos);
	
	}
	else if (quints == 1)
	{
		outputs = 0;
		bitpos = 0;

		int b0 = numbers[0];
		int b1 = numbers[1];
		int b2 = numbers[2];
		encode_quints(bits, b0, b1, b2, outputs, bitpos);

		b0 = numbers[3];
		b1 = numbers[4];
		b2 = numbers[5];
		encode_quints(bits, b0, b1, b2, outputs, bitpos);

		b0 = numbers[6];
		b1 = numbers[7];
		b2 = numbers[8];
		encode_quints(bits, b0, b1, b2, outputs, bitpos);

		b0 = numbers[9];
		b1 = numbers[10];
		b2 = numbers[11];
		encode_quints(bits, b0, b1, b2, outputs, bitpos);

		b0 = numbers[12];
		b1 = numbers[13];
		b2 = numbers[14];
		encode_quints(bits, b0, b1, b2, outputs, bitpos);

		b0 = numbers[15];
		encode_quints(bits, b0, 0, 0, outputs, bitpos);

	}
	else
	{
		int outs[16],

		bitpos = 0;
		int i = 0;
		for (i = 0; i < 16; ++i)
		{
			outs[i] = 0;
		}
		for (i = 0; i < 16; ++i)
		{
			int idx = bitpos / 8;
			int offset = bitpos % 8;
			int mask = (numbers[i] << offset);
			outs[idx] |= mask & 0xFF;
			outs[idx + 1] |= (mask >> 8) & 0xFF;
			bitpos += bits;
		}

		outputs = array16_2_int4(outs);

	}

}

