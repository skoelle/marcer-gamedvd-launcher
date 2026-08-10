// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

namespace MarcerGameDvdLauncher
{
    public class HatariLauncher
    {
        private readonly string _exePath;
        private readonly string _cfgPath;
        private readonly string _argsTemplate;

        public HatariLauncher(string exePath, string cfgPath, string argsTemplate)
        {
            if (string.IsNullOrWhiteSpace(exePath))
                throw new ArgumentNullException(nameof(exePath));

            // Defensive validation: ensure the executable exists
            if (!File.Exists(exePath))
                throw new ArgumentException($"Hatari executable not found: {exePath}", nameof(exePath));

            _exePath = exePath;
            _cfgPath = cfgPath;
            _argsTemplate = argsTemplate;
        }

        /// <summary>
        /// Starts Hatari with the given ZIP file. ArgsTemplate is used to build the arguments,
        /// replacing {cfg} and {zip} placeholders.
        /// </summary>
        public void Launch(string zipFilePath)
        {
            if (string.IsNullOrWhiteSpace(zipFilePath))
                throw new ArgumentException("ZIP archive path must not be empty.", nameof(zipFilePath));
            try
            {
                string args = _argsTemplate.Replace("{cfg}", _cfgPath).Replace("{zip}", zipFilePath);

                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = _exePath,
                    Arguments = args,
                    UseShellExecute = false,
                    WorkingDirectory = Path.GetDirectoryName(_exePath) ?? string.Empty
                };
                System.Diagnostics.Process.Start(psi);
                // Show a modal indicating the emulator was started and wait until
                // the user releases the Return key before clearing the modal. This
                // prevents accidental key repeats from triggering other actions.
                ProgramHelpers.ShowModalUntilReturnReleased("Hatari started. Release Return to continue...");
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException($"Error starting Hatari: {ex.Message}", ex);
            }
        }
    }
}
