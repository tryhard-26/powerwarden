#if defined(__arm64__)
	.text
	.globl	_pw_tick
	.p2align 2
// raw CNTVCT_EL0, same clk as mach_absolute_time, no commpage call
_pw_tick:
	isb
	mrs	x0, CNTVCT_EL0
	ret
#endif
