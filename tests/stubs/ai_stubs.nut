// tests/stubs/ai_stubs.nut
// Minimal stand-ins so sq.exe can load src/*.nut files outside OpenTTD.
// Pure modules don't really call these; AI* symbols just need to exist
// at parse time. Modules that DO call AI* are not tested here.

if (!("AILog" in getroottable())) {
    AILog <- {
        function Info(s)    { print("[stub AILog.Info] " + s + "\n"); }
        function Warning(s) { print("[stub AILog.Warn] " + s + "\n"); }
        function Error(s)   { print("[stub AILog.Err]  " + s + "\n"); }
    };
}

// `require` is provided by OpenTTD's loader. In sq.exe we shim it to
// dofile so source files using require() still load.
if (!("require" in getroottable())) {
    require <- function(path) { dofile(path); };
}
