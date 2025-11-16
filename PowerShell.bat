@echo off
powershell.exe -ep bypass -nop -nol -c "$p = (cat -Raw '%~f0') -split 'GOTO:EOF'; if ($p.Count -ne 3) { throw 'Split Error' }; iex $p[2].TrimStart()"
GOTO:EOF


Write-Host "Hello, World!" -ForegroundColor Red -BackgroundColor Green
Read-Host -Prompt "Press any key to continue"

