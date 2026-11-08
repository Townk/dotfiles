// params.scad — every dimension, in millimetres. Include this; never hard-code a value in a part.
//
// Parts are modelled in place, in FRAME coordinates:
//   X  ...
//   Y  ...
//   Z  up, 0 = ...
// Values marked MEASURE are estimates; the coupon or caliper that settles each is in docs/measurements.md.

$fn = 48;

include <params/common.scad>
