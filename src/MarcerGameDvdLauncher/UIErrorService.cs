// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

namespace MarcerGameDvdLauncher;

/// <summary>
/// Centralized service for error and user message output in the console UI.
/// Errors are presented to the user via <see cref="ProgramHelpers.ShowConsoleMessage"/>
/// and are not rethrown — the caller's context does not allow for meaningful error
/// recovery, so the application stays in the navigation loop after the user dismisses
/// the message.
/// </summary>
public class UIErrorService
{
    public void ShowError(string message)
    {
        ProgramHelpers.ShowConsoleMessage([message], ConsoleColor.Red, clear: false, waitForKey: true);
    }
}