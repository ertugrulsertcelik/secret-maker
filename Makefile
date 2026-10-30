# Kısayollar: make <hedef>
.PHONY: help build run install release cli icon clean

help:
	@echo "make install   Derle, /Applications'a kur ve aç (günlük kullanım)"
	@echo "make run       Derle ve build/ klasöründen aç"
	@echo "make build     Sadece derle (build/Secret Bot.app)"
	@echo "make release   Intel + Apple Silicon zip (dist/)"
	@echo "make cli       Test aracını derle (.build/debug/secretbot-cli)"
	@echo "make icon      Simgeyi yeniden üret"
	@echo "make clean     Derleme çıktılarını sil"

build:
	./build.sh

run: build
	-@osascript -e 'quit app "Secret Bot"' >/dev/null 2>&1
	open "build/Secret Bot.app"

install:
	./build.sh --install

release:
	./build.sh --universal --zip

cli:
	swift build --product secretbot-cli

icon:
	./icon/make_icns.sh

clean:
	rm -rf .build build dist
