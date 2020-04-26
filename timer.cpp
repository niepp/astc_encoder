#include "timer.h"

double Timer::m_reci_freq = 0;

Timer::Timer()
{
	if (!m_reci_freq)
	{
		LARGE_INTEGER temp;
		::QueryPerformanceFrequency(&temp);
		m_reci_freq = (double)(1000.0 / temp.QuadPart);
	}
	Reset();
}

uint64_t Timer::GetTick() const
{
	uint64_t tick = 0;
	::QueryPerformanceCounter((LARGE_INTEGER*)&tick);
	return tick;
}

void Timer::Reset()
{
	m_start_count = GetTick();
}

float Timer::GetElapseMilliseconds() const
{
	uint64_t tick = GetTick();
	return (float)((tick - m_start_count) * m_reci_freq);
}

float Timer::GetElapseSeconds() const
{
	uint64_t tick = GetTick();
	return (float)((tick - m_start_count) * m_reci_freq / 1000.0f);
}
