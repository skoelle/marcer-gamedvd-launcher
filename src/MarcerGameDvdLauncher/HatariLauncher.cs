// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

namespace MarcerGameDvdLauncher
{
    public class HatariLauncher
    {
        // The Hatari configuration file that is shipped with the launcher.
        // When Hatari.ConfigFile is not set in launcher.config.json, this file
        // (resolved relative to the executable directory) is used automatically.
        public const string DefaultConfigFile = "MarcerGameDvd-Hatari.cfg";

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

            // Validate argsTemplate
            if (string.IsNullOrWhiteSpace(argsTemplate) || !argsTemplate.Contains("{zip}"))
                throw new ArgumentException("Hatari.ArgsTemplate must contain the {zip} placeholder.", nameof(argsTemplate));

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
                // Build arguments: only include config section if cfgPath is not empty
                string args = _argsTemplate;
                if (!string.IsNullOrWhiteSpace(_cfgPath))
                {
                    args = args.Replace("{cfg}", _cfgPath);
                }
                else
                {
                    // Remove {cfg} placeholder entirely if config file is empty
                    args = args.Replace("{cfg}", string.Empty);
                }
                args = args.Replace("{zip}", zipFilePath);

                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = _exePath,
                    Arguments = args,
                    UseShellExecute = false,
                    WorkingDirectory = Directory.GetCurrentDirectory()
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
