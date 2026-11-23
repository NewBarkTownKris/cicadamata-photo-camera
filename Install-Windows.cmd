@echo off
setlocal
where py >nul 2>nul
if errorlevel 1 goto python
py -3 "%~dp0tools\install.py" %*
goto done
:python
python "%~dp0tools\install.py" %*
:done
set "code=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %code%
