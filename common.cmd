REM ---- Shared settings ----
REM Use this script's folder name as Docker name
for %%I in ("%~dp0.") do set "DOCKER_NAME=%%~nI"

REM Optional: replace spaces with underscores (Docker names can't contain spaces)
set "DOCKER_NAME=%DOCKER_NAME: =_%"