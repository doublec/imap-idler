.PHONY: all run
all: idle1

idle1: idle/main.pony
	ponyc idle

run:
	./idle1
