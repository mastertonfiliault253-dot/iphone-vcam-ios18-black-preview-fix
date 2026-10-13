@echo off
set HTTP_PROXY=http://127.0.0.1:7897
set HTTPS_PROXY=http://127.0.0.1:7897
set NO_PROXY=gsa.apple.com,gsa2.apple.com,gsa-cdn.apple.com,developerservices2.apple.com,developerservices.apple.com,gs.apple.com,gs-loc.apple.com
set no_proxy=%NO_PROXY%
start "" "C:\Users\Administrator\AppData\Local\Sideloadly\sideloadly.exe"
