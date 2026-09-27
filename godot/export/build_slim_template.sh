#!/usr/bin/env bash
# Compila la plantilla de exportación reducida de Windows usada para el .exe de la demo
# (< 30 MiB). Requiere: código fuente de Godot 4.7.2-stable, scons y mingw-w64 (posix).
#   ./build_slim_template.sh /ruta/a/godot-4.7.2-stable [windows|linuxbsd]
# Resultado: <godot>/bin/godot.<plataforma>.template_release.x86_64.slim(.exe)
# Copiar el .exe de Windows a godot/build/templates/ y exportar con el preset "Windows Slim".
set -euo pipefail
SRC="${1:?ruta al código fuente de Godot}"
PLATFORM="${2:-windows}"
PROFILE="$(cd "$(dirname "$0")" && pwd)/slim_template.build"
EXTRA=()
if [ "$PLATFORM" = "windows" ]; then
	EXTRA=(use_mingw=yes d3d12=no winrt=no accesskit=no)
else
	EXTRA=(wayland=no accesskit=no dbus=no speechd=no fontconfig=no udev=no)
fi
cd "$SRC"
scons platform="$PLATFORM" target=template_release arch=x86_64 "${EXTRA[@]}" \
	production=yes optimize=size_extra lto=full debug_symbols=no deprecated=no \
	vulkan=no opengl3=yes sdl=yes brotli=yes graphite=no \
	disable_physics_2d=yes disable_navigation_2d=yes disable_navigation_3d=yes disable_xr=yes \
	disable_advanced_gui=yes build_profile="$PROFILE" \
	modules_enabled_by_default=no module_gdscript_enabled=yes module_freetype_enabled=yes \
	module_text_server_fb_enabled=yes module_godot_physics_3d_enabled=yes \
	extra_suffix=slim
