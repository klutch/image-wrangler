#include "iw_math_compat.h"

using namespace godot;

void IWMathCompat::_bind_methods() {
	ClassDB::bind_method(D_METHOD("roundi", "value"), &IWMathCompat::roundi);
	ClassDB::bind_method(D_METHOD("clampf", "value", "lo", "hi"), &IWMathCompat::clampf);
	ClassDB::bind_method(D_METHOD("lerpf", "from", "to", "weight"), &IWMathCompat::lerpf);
	ClassDB::bind_method(D_METHOD("narrow", "value"), &IWMathCompat::narrow);
}

int64_t IWMathCompat::roundi(double value) const {
	return iw::roundi(value);
}

double IWMathCompat::clampf(double value, double lo, double hi) const {
	return iw::clampf(value, lo, hi);
}

double IWMathCompat::lerpf(double from, double to, double weight) const {
	return iw::lerpf(from, to, weight);
}

double IWMathCompat::narrow(double value) const {
	return iw::widen(iw::narrow(value));
}
