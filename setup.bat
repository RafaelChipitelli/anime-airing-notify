@echo off
title anime-airing-notify setup
rem Double-click installer for Windows: runs the same setup.ps1 everyone else
rem uses (see the repo for its source). Keeps the window open at the end.
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; irm https://raw.githubusercontent.com/RafaelChipitelli/anime-airing-notify/main/setup.ps1 | iex"
echo.
pause
