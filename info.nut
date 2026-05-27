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
    function GetAPIVersion()    { return "1.12"; }  // adjust to match your OpenTTD if needed
    function GetURL()           { return ""; }

    // Optional settings would go here. None for v1.
}

RegisterAI(MvBAIInfo());
