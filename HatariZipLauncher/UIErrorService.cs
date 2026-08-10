namespace HatariZipLauncher;

/// <summary>
/// Centralized service for error and user message output in the console UI.
/// </summary>
public class UIErrorService
{
    public void ShowError(string message)
    {
        ProgramHelpers.ShowConsoleMessage([message], ConsoleColor.Red, clear: false, waitForKey: true);
    }
}