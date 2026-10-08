#!/usr/bin/env bash
# Берёт ту же логику входа и установки, что у kombain-start.exe (starter/backend.go),
# и кладёт её копию сюда под именем пакета kbcore. Один код — две программы.
set -euo pipefail
cd "$(dirname "$0")"
{ echo "// Сгенерировано из starter/backend.go (gen.sh). Не править — правь оригинал."; sed 's/^package main$/package kbcore/' ../../starter/backend.go; } > backend_gen.go
