@echo off
call "%~dp0common.cmd"

docker stop %DOCKER_NAME% >nul 2>nul
