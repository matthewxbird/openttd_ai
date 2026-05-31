// Match observer GameScript: logs every company's value once a year so an
// external harness can score an unattended headless match. Neutral - it only
// reads and reports, never touches the game.
class MvBObserver extends GSInfo {
    function GetAuthor()       { return "MvB"; }
    function GetName()         { return "MvBObserver"; }
    function GetShortName()    { return "MVBO"; }
    function GetDescription()  { return "Logs each company's value yearly for headless match scoring."; }
    function GetVersion()      { return 1; }
    function GetDate()         { return "2026-05-31"; }
    function CreateInstance()  { return "MvBObserver"; }
    function GetAPIVersion()   { return "15"; }
    function GetURL()          { return ""; }
}

RegisterGS(MvBObserver());
