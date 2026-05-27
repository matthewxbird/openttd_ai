// src/logger.nut
// Thin wrapper around AILog so every log line is prefixed with a phase tag.
// In-game AI Debug window shows these prefixes, making it easy to filter
// "what was the AI doing" by scanning for [BOOT], [SCAN], [TRACK], etc.
//
// Usage:
//   Log.Info("BOOT", "starting up");
//   Log.Warn("TRACK", "pathfinder retry");
//   Log.Err ("TRACK", "blacklisted pair");

class Log {
    // Phase tags we use across the project. Kept as constants so typos surface fast.
    static PHASE_BOOT    = "BOOT";
    static PHASE_SCAN    = "SCAN";
    static PHASE_RANK    = "RANK";
    static PHASE_MONEY   = "MONEY";
    static PHASE_STATION = "STATION";
    static PHASE_TRACK   = "TRACK";
    static PHASE_SIGNAL  = "SIGNAL";
    static PHASE_TRAIN   = "TRAIN";
    static PHASE_REPLACE = "REPLACE";
    static PHASE_LOOP    = "LOOP";

    // Informational. Default level — shows up in AI Debug window.
    static function Info(phase, msg) {
        AILog.Info("[" + phase + "] " + msg);
    }

    // Recoverable problem. Yellow in the AI Debug window.
    static function Warn(phase, msg) {
        AILog.Warning("[" + phase + "] " + msg);
    }

    // Gave-up / blacklist / unexpected. Red in the AI Debug window.
    static function Err(phase, msg) {
        AILog.Error("[" + phase + "] " + msg);
    }
}
