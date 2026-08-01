Set shell = CreateObject("WScript.Shell")
shell.Run "netsh advfirewall firewall add rule name=""Headroom 18787"" dir=in action=allow protocol=tcp localport=18787 program=""C:\Users\ma dao\.headroom-venv\Scripts\python.exe"" enable=yes", 0, True
