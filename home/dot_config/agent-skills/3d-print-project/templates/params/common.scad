// params/common.scad — fits, hardware, colours, the printer. Units mm.

eps = 0.01;

// ---------- fits (each settled by a coupon: docs/measurements.md) ----------
fit      = 0.3;                       // MEASURE: a part in its pocket, per side
part_gap = 0.3;                       // between neighbouring printed parts

// ---------- hardware the user has ----------
m3_clear_d = 3.4;
m3_head    = [6.0, 3.0];              // socket head: diameter, height
insert_m3  = [4.0, 5.7];              // heat-set insert: hole diameter, length

// ---------- colours (scripts/print_parts.py COLOURS: c_<key>) ----------
c_white = "#e9e9e6";
c_black = "#1c1c1e";

// ---------- printer ----------
bed = [340, 320, 340];                // Bambu Lab H2S
