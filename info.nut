// info.nut
// Tells OpenTTD what this AI is called and which class to instantiate.
// OpenTTD loads this file first, calls RegisterAI() to wire us in,
// then later instantiates the class named in CreateInstance.

class MvBAIInfo extends AIInfo {
    function GetAuthor()        { return "Matthew van Bird"; }
    function GetName()          { return "MvB AI"; }
    function GetDescription()   { return "Builds double-track rail routes ranked by ROI across all cargoes."; }
    function GetVersion()       { return 1; }
    function GetDate()          { return "2026-05-27"; }
    function CreateInstance()   { return "MvBAI"; }
    function GetShortName()     { return "MVBA"; }  // 4 chars, unique tag
    function GetAPIVersion()    { return "15"; }  // valid range: "12".."15". Use "14" for stable 14.x release.
    function GetURL()           { return ""; }

    function GetSettings() {
        AddSetting({
            name = "disable_air",
            description = "Disable air: build no airports and skip scanning air routes",
            easy_value = 0, medium_value = 0, hard_value = 0, custom_value = 0,
            flags = AICONFIG_BOOLEAN | AICONFIG_INGAME
        });
    }
}

RegisterAI(MvBAIInfo());
