#include "csdl.h"
#include <float.h>

void Evolve(uint64_t* pState, uint64_t Rule, uint64_t Order)
{
	uint64_t State = *pState;
	uint64_t OrderMask = (1ul<<Order)-1;
	uint64_t NumBits = 64;
	uint64_t Next = 0;
	for(uint64_t i=0; i<NumBits; i++)
	{
		uint64_t idx = (i+NumBits-1)%NumBits;
		uint64_t Key = ((State>>idx) | (State <<(NumBits-idx))) & OrderMask;
		uint64_t Bit = (Rule & (1ul<<Key)) ? 1 : 0;
		Next |= Bit << i;
	}
	*pState = Next;
}

void PrintState(uint64_t State)
{
	uint64_t NumBits = 64;
	for(uint64_t i=0; i<NumBits; i++)
	{
		char Glyph = (State & (1ul<<i)) != 0 ? '*' : ' ';
		printf("%c", Glyph);
	}
	printf("\n");
}

MYFLT CaToFloat(uint64_t State)
{
	double AsDouble = (double)State;
	AsDouble /= (double)ULONG_MAX;
	MYFLT AsMyFlt = (MYFLT)(AsDouble * 2.0 - 1.0);
	return AsMyFlt;
}

uint64_t CaSeed(MYFLT SeedVal, uint64_t Rule, uint64_t Order)
{
	uint64_t result = 0;
	if(SeedVal < FLT_EPSILON && SeedVal > -FLT_EPSILON)
	{
		result = 1ul << 15;
		for(int i=0; i<32; i++)
		{
			Evolve(&result, Rule, Order);
		}
	}
	else
	{
		result = (uint64_t)(SeedVal);
	}
	return result;
}

typedef struct _CaOscilOpcode {
	OPDS h;
	MYFLT *out;
	MYFLT *in_speedmod;
	MYFLT *in_rule;
	MYFLT *in_order;
	MYFLT *in_seed;

	uint64_t state;
	uint64_t rule;
	uint64_t order;

	double TimeUntilNextSample;
	MYFLT currentVal;
	MYFLT targetVal;
	MYFLT delta;
} CaOscilOpcode;

int32_t CaOscilOpcode_Init(CSOUND *csound, CaOscilOpcode *p)
{
	p->rule = (uint64_t)(*p->in_rule);
	p->order = (uint64_t)(*p->in_order);
	p->state = CaSeed(*(p->in_seed), p->rule, p->order);

	p->targetVal = p->currentVal = CaToFloat(p->state);
	p->delta = 0.0;
	p->TimeUntilNextSample = 0.0;

	return OK;
}

int32_t CaOscilOpcode_Process(CSOUND *csound, CaOscilOpcode *p)
{
	int i;
	int n = CS_KSMPS;
	MYFLT SpeedMod = fabs((*p->in_speedmod));

	// if speed is 0 we are done, just repeat value
	if(SpeedMod < FLT_EPSILON)
	{
		for(i=0; i<n; i++)
		{
			p->out[i] = p->currentVal;
		}
		return OK;
	}
	
	for(i=0; i<n; i++)
	{
		p->TimeUntilNextSample -= SpeedMod;
		while(p->TimeUntilNextSample < FLT_EPSILON)
		{
			Evolve(&(p->state), p->rule, p->order);
			p->targetVal = CaToFloat(p->state);
			p->delta = (p->targetVal - p->currentVal);
			p->TimeUntilNextSample += 1.0;
		}

		int bMaxCheck = p->currentVal < p->targetVal;
		p->currentVal += p->delta * SpeedMod;
		p->currentVal = bMaxCheck ? fmin(p->currentVal, p->targetVal) : fmax(p->currentVal, p->targetVal);
		
		p->out[i] = p->currentVal;
		
	}
	return OK;
}

typedef struct _CaOscilOpcodeR {
	OPDS h;
	MYFLT *out;
	MYFLT* in_speedmod;
	MYFLT* in_reset;
	MYFLT *in_rule;
	MYFLT* in_order;
	MYFLT* in_seed;

	uint64_t state;
	uint64_t rule;
	uint64_t order;

	double TimeUntilNextSample;
	MYFLT currentVal;
	MYFLT targetVal;
	MYFLT delta;
} CaOscilOpcodeR;

int32_t CaOscilOpcodeR_Init(CSOUND *csound, CaOscilOpcodeR *p)
{
	p->rule = (uint64_t)(*p->in_rule);
	p->order = (uint64_t)(*p->in_order);
	p->state = CaSeed(*(p->in_seed), p->rule, p->order);

	p->targetVal = p->currentVal = CaToFloat(p->state);
	p->delta = 0.0;
	p->TimeUntilNextSample = 0.0;

	return OK;
}

int32_t CaOscilOpcodeR_Process(CSOUND *csound, CaOscilOpcodeR *p)
{
	int i;
	int n = CS_KSMPS;
	MYFLT SpeedMod = fabs((*p->in_speedmod));

	// if speed is 0 we are done, just repeat value
	if(SpeedMod < FLT_EPSILON)
	{
		for(i=0; i<n; i++)
		{
			p->out[i] = p->currentVal;
		}
		return OK;
	}
	
	for(i=0; i<n; i++)
	{
		p->TimeUntilNextSample -= SpeedMod;

		MYFLT Reset = p->in_reset[i];
		if(Reset > FLT_EPSILON || Reset < -FLT_EPSILON)
		{
			p->state = CaSeed(*(p->in_seed), p->rule, p->order);
			p->TimeUntilNextSample = 0.0;
		}

		while(p->TimeUntilNextSample < FLT_EPSILON)
		{
			Evolve(&(p->state), p->rule, p->order);
			p->targetVal = CaToFloat(p->state);
			p->delta = (p->targetVal - p->currentVal);
			p->TimeUntilNextSample += 1.0;
		}

		int bMaxCheck = p->currentVal < p->targetVal;
		p->currentVal += p->delta * SpeedMod;
		p->currentVal = bMaxCheck ? fmin(p->currentVal, p->targetVal) : fmax(p->currentVal, p->targetVal);
		
		p->out[i] = p->currentVal;
		
	}
	return OK;
}

typedef struct _CaOscilOpcodeK {
	OPDS h;
	MYFLT *out;
	MYFLT *in_rule;
	MYFLT* in_order;
	MYFLT* in_seed;

	uint64_t state;
	uint64_t rule;
	uint64_t order;
} CaOscilOpcodeK;

int32_t CaOscilOpcodeK_Init(CSOUND *csound, CaOscilOpcodeK *p)
{
	p->rule = (uint64_t)(*p->in_rule);
	p->order = (uint64_t)(*p->in_order);
	p->state = CaSeed(*(p->in_seed), p->rule, p->order);

	return OK;
}

int32_t CaOscilOpcodeK_Process(CSOUND *csound, CaOscilOpcodeK *p)
{
	Evolve(&(p->state), p->rule, p->order);
	*(p->out) = CaToFloat(p->state);
	return OK;
}


static OENTRY localops[] = {
	{"caoscil", sizeof(CaOscilOpcode), 0, 3, "a", "kiio", (SUBR)CaOscilOpcode_Init, (SUBR)CaOscilOpcode_Process},
	{"caoscilr", sizeof(CaOscilOpcodeR), 0, 3, "a", "aaiio", (SUBR)CaOscilOpcodeR_Init, (SUBR)CaOscilOpcodeR_Process},
	{"caoscilk", sizeof(CaOscilOpcodeK), 0, 3, "k", "iio", (SUBR)CaOscilOpcodeK_Init, (SUBR)CaOscilOpcodeK_Process}
};

LINKAGE