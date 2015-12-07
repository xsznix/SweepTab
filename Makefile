debug:
	lsc -m embedded -o build/debug -c src
	rsync -avzh src/assets build/debug