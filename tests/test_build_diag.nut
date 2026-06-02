// tests/test_build_diag.nut
// Unit tests for BuildDiag.Classify - the PURE build-failure classifier (Phase 8).
// Args: (err_name, owner_mine, owner_none, is_rail, is_water, is_station, is_buildable)

(function() {
    // Rival rail -> detour (can't build on / demolish foreign property).
    {
        local d = BuildDiag.Classify("ERR_OWNED_BY_ANOTHER_COMPANY",
            false, false, true, false, false, false);
        assert_eq(d.recover, "detour", "rival rail -> detour");
        assert_true(d.cause.find("rival-owned") != null, "names rival ownership");
    }
    // Rival station -> detour.
    {
        local d = BuildDiag.Classify("UNKNOWN", false, false, false, false, true, false);
        assert_eq(d.recover, "detour", "rival station -> detour");
    }
    // Our own rail in the way -> detour.
    {
        local d = BuildDiag.Classify("ERR_ALREADY_BUILT", true, false, true, false, false, false);
        assert_eq(d.recover, "detour", "own rail -> detour");
        assert_true(d.cause.find("our own") != null, "names own rail");
    }
    // Water -> bridge it (terraform recovery hint).
    {
        local d = BuildDiag.Classify("UNKNOWN", false, true, false, true, false, false);
        assert_eq(d.recover, "terraform", "water -> terraform/bridge");
    }
    // Tunnel-on-water surfaces even without the water fact, via the err name.
    {
        local d = BuildDiag.Classify("ERR_TUNNEL_CANNOT_BUILD_ON_WATER",
            false, true, false, false, false, false);
        assert_eq(d.recover, "terraform", "tunnel-on-water -> terraform/bridge");
    }
    // Area not clear (clearable obstacle) -> terraform.
    {
        local d = BuildDiag.Classify("ERR_AREA_NOT_CLEAR",
            false, true, false, false, false, false);
        assert_eq(d.recover, "terraform", "area not clear -> terraform");
    }
    // Unowned rough/unbuildable ground (no error name) -> terraform.
    {
        local d = BuildDiag.Classify("UNKNOWN", false, true, false, false, false, false);
        assert_eq(d.recover, "terraform", "rough unowned ground -> terraform");
    }
    // The whole point: ERR_UNKNOWN on buildable unowned land is NOT swallowed -
    // it's reported with the raw tile facts so a human can see them.
    {
        local d = BuildDiag.Classify("ERR_UNKNOWN", false, true, false, false, false, true);
        assert_eq(d.recover, "none", "truly unknown -> none");
        assert_true(d.cause.find("unclassified") != null, "ERR_UNKNOWN labelled unclassified");
        assert_true(d.cause.find("buildable=true") != null, "reports raw tile facts");
    }
})();
