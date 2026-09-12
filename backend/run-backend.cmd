@echo off
cd /d D:\she-v3\backend
REM load .env (SPRING_PROFILES_ACTIVE comes from .env itself)
for /f "usebackq tokens=1,* delims==" %%a in (".env") do (
  set "%%a=%%b"
)
set SPRING_PROFILES_ACTIVE=local
mvn spring-boot:run > run-backend.log 2>&1