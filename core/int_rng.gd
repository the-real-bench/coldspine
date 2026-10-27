class_name IntRng
extends RefCounted
## Hand-rolled seeded integer PRNG (xorshift32). Identical streams on every
## platform — guaranteed by 32-bit masking and zero float / wall-clock use.
## PHYSICS NEVER TOUCHES THIS. Only combat to-hit and content rolls draw from it.

var state: int = 0x9E3779B9  # nonzero default

func _init(seed: int = 0x9E3779B9) -> void:
	set_seed(seed)

func set_seed(seed: int) -> void:
	state = seed & 0xFFFFFFFF
	if state == 0:
		state = 0x9E3779B9  # xorshift cannot be seeded with 0

func next_u32() -> int:
	var x: int = state & 0xFFFFFFFF
	x ^= (x << 13) & 0xFFFFFFFF
	x ^= (x >> 17)
	x ^= (x << 5) & 0xFFFFFFFF
	state = x & 0xFFFFFFFF
	return state

## Inclusive range [lo, hi].
## IMPORTANT: each helper calls next_u32() DIRECTLY and captures the word in a
## local before doing any arithmetic. Delegating one helper to another
## (chance -> randi_range -> next_u32) or folding the draw into a compound
## expression tripped a GDScript 4.7 codegen defect where the inner mutation of
## self.state was dropped and the result computed on stale data — the PRNG froze
## and rolls went nondeterministic. A single direct next_u32() call captured to a
## local compiles correctly; the determinism tests are the guard against regress.
func randi_range(lo: int, hi: int) -> int:
	if hi <= lo:
		return lo
	var u: int = next_u32()
	return lo + (u % (hi - lo + 1))

## Roll a percentage check: returns true with `pct` chance (0..100).
func chance(pct: int) -> bool:
	var u: int = next_u32()
	var roll: int = 1 + (u % 100)
	return roll <= pct

func clone() -> IntRng:
	var r := IntRng.new()
	r.state = state
	return r
