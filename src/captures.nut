// src/captures.nut
// CAPTURED in-game rail layouts (scanned from AAAHogEx via JunctionBuilder.ScanToLog).
// Ground-truth geometry to replay with JunctionBuilder.StampList, so we build
// PROVEN throats instead of hand-guessing tile bits. See docs/RAIL_REWRITE.md.
//
// Trackbits: 1=NE_SW 2=NW_SE 4=NW_NE 8=SW_SE 16=NW_SW 32=NE_SE (sums combine).
// Signal types: 1=normal 2=entry 3=exit 4=combo 5=PBS(2-way) 6=PBS(1-way).

class Captures {

    // 2-PLATFORM throat (Charnbury East area, scanned 2026-06-05; box origin
    // (100,197)). REBASED to 0-origin (min dx=12, min dy=6). Two platform tracks
    // (rows dy0/dy1) run straight (bits=1) out of the platforms (toward -x); a
    // CROSSOVER turnout at dx4 (corners 41 = 1+8+32, 21 = 1+4+16) ties the two
    // tracks together; the exit is dx5 with combo presignals (row0 faces out +x =
    // DEPARTURE, row1 faces in -x = ARRIVAL). Far simpler than the 3-platform
    // bridged merge - a cheap small-station opener. Platforms are built separately
    // (BuildRailStation); stamp only the crossover (dx>=4).
    static function TwoPlatThroat() {
        return [
            ["R",0,0,1],["R",1,0,1],["R",2,0,1],["R",3,0,1],["R",4,0,41],["R",5,0,1],
            ["S",5,0,6,0,4],
            ["R",0,1,1],["R",1,1,1],["R",2,1,1],["R",3,1,1],["R",4,1,21],["R",5,1,1],
            ["S",5,1,4,1,4],
        ];
    }

    // AAHOG "Wronston" station throat+main junction, scanned 2026-06-05 from a live
    // 1v1 (box origin (70,205), 23x23). REBASED to 0-origin (subtracted min dx=4,
    // min dy=3). 3 platform rows (dy 1,2,3) run straight (bits=1) on the west side
    // (dx 0..6); the THROAT merge is dx ~7..12 (corner bits + a grade-sep BRIDGE
    // dy2 dx9->12) so arrival/departure don't conflict; the double main continues
    // east (dx 12..18). Combo signals (type4) at the dx6 column = throat entry;
    // PBS (type5) guard the merge diamonds + bridge mouths.
    static function WronstonThroat() {
        return [
            // --- row dy0 (was Y208): a single main-corner tile at the far east ---
            ["R",18,0,8],
            ["S",18,0,18,1,5],
            // --- row dy1 (Y209): platform/main line, throat curves at dx7,10,11 ---
            ["R",0,1,1],["R",1,1,1],["R",2,1,1],["R",3,1,1],["R",4,1,1],["R",5,1,1],
            ["R",6,1,1],["S",6,1,5,1,4],
            ["R",7,1,33],["R",8,1,1],["R",9,1,1],["R",10,1,33],["R",11,1,9],
            ["R",12,1,1],["S",12,1,11,1,5],
            ["R",13,1,1],["R",14,1,1],["R",15,1,1],["R",16,1,1],["R",17,1,1],["R",18,1,4],
            // --- row dy2 (Y210): 2nd line; BRIDGE dx9->12 grade-separates the merge ---
            ["R",0,2,1],["R",1,2,1],["R",2,2,1],["R",3,2,1],["R",4,2,1],["R",5,2,1],
            ["R",6,2,1],["S",6,2,5,2,4],
            ["R",7,2,57],["R",8,2,1],["S",8,2,9,2,5],
            ["B",9,2,12,2],                       // grade-separation bridge
            ["R",10,2,24],["R",11,2,38],["S",13,2,14,2,5],
            ["R",13,2,1],["R",14,2,1],["R",15,2,1],["R",16,2,1],["R",17,2,1],["R",18,2,1],
            // --- row dy3 (Y211): 3rd platform line, curves into the merge at dx7,10,11 ---
            ["R",0,3,1],["R",1,3,1],["R",2,3,1],["R",3,3,1],["R",4,3,1],["R",5,3,1],
            ["R",6,3,1],["S",6,3,5,3,4],
            ["R",7,3,21],["R",8,3,1],["R",9,3,1],["R",10,3,5],["R",11,3,17],
        ];
    }
}
