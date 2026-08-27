@echo off
rem Host-side setup for the dev container, run from the opened repo root.
rem Windows counterpart of ./initialize: docker-compose.override.yml is
rem git-ignored but referenced in devcontainer.json, so create an empty stub
rem when missing (Compose v2 merges it as a no-op).
if not exist docker-compose.override.yml type nul > docker-compose.override.yml
