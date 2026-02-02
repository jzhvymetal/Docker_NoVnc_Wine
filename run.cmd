@echo off
call "%~dp0common.cmd"

docker stop %DOCKER_NAME% >nul 2>nul
docker rm %DOCKER_NAME% >nul 2>nul

docker run -it --name %DOCKER_NAME% --privileged ^
  -p 8080:8080 -p 22:22 -p 5900:5900 -p 6001:6001 -p 13777:13777 -p 10000:10000 ^
  -v "%~dp0data:/data" ^
  -e SCREEN_WIDTH=1024 ^
  -e SCREEN_HEIGHT=600 ^
  -e XPRA_PASSWORD=pass ^
  -e STARTUP_SCRIPT=\data\vijeo\vijeo-startup.sh ^
  %DOCKER_NAME%:latest & call :cleanup & call :cleanup

exit /b

:cleanup
docker stop %DOCKER_NAME% >nul 2>nul
exit /b