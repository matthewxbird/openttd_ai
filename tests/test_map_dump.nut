// tests/test_map_dump.nut
// Unit tests for the PURE downsample-step helper in MapDump.

(function() {
    // Span fits within max -> step 1 (no downsampling).
    assert_eq(MapDump.Step(10, 56), 1, "small span -> step 1");
    assert_eq(MapDump.Step(56, 56), 1, "span == max -> step 1");

    // Span larger than max -> ceil(span/max).
    assert_eq(MapDump.Step(57, 56), 2, "just over max -> step 2");
    assert_eq(MapDump.Step(112, 56), 2, "2x max -> step 2");
    assert_eq(MapDump.Step(113, 56), 3, "just over 2x -> step 3");

    // Guards.
    assert_eq(MapDump.Step(0, 56), 1, "zero span -> step 1");
    assert_eq(MapDump.Step(10, 0), 10, "zero max clamps to 1 -> step = span");
})();
