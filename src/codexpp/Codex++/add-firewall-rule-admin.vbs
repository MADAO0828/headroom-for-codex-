Set shell = CreateObject("Shell.Application")
shell.ShellExecute "netsh", "advfirewall firewall add rule name=""Headroom 18787"" dir=in action=allow protocol=tcp localport=18787 program=""C:\Users\ma dao\.headroom-venv\Scripts\python.exe"" enable=yes", "", "runas", 0
