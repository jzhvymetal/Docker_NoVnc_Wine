@echo off
call "%~dp0common.cmd"

REM --no-cache

docker build --build-arg HTTP_PROXY="http://192.168.10.233:8118" --build-arg HTTPS_PROXY="http://192.168.10.233:8118" -t %DOCKER_NAME% .

IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%

call "%~dp0run.cmd"
