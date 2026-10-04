all: lint format-check shaders-format-check
version = "0.9.0"

format-check:
	find source/ -name '*.gd' | xargs gdformat --check

shaders-format-check:
	find source/ -name '*.gdshader' | xargs clang-format --style=file --dry-run -Werror

lint:
	find source/ -name '*.gd' | xargs gdlint

cc:
	find source/ -name '*.gd' | xargs gdradon cc

todo:
	ack ' todo' -i source/

build-info:  # commit and branch for crash reports from exported builds
	printf '{"commit": "%s", "branch": "%s"}\n' "$$(git rev-parse --short=10 HEAD)" "$$(git rev-parse --abbrev-ref HEAD)" > build_info.json

release-linux: build-info
	godot4 --export-release "Linux/X11" "build/Open_RTS_$(version)_linux64.bin"

release-macos: build-info
	godot4 --export-release "macOS" "build/Open_RTS_$(version)_osx64.zip"

release-windows: build-info
	godot4 --export-release "Windows Desktop" "build/Open_RTS_$(version)_windows64.exe"

release: release-linux release-macos release-windows
