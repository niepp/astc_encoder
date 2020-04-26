#pragma once

#ifndef __TIMER_H__
#define __TIMER_H__

#include <windows.h>
#include <stdint.h>

class Timer
{
public:
	Timer();
	void Reset();
	float GetElapseMilliseconds() const;
	float GetElapseSeconds() const;
private:
	uint64_t GetTick() const;
private:
	uint64_t m_start_count;
	static double m_reci_freq;
};

#endif // __TIMER_H__
