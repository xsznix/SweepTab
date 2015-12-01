debug:
	lsc -b -o build/debug -c src
	rsync -avzh src/assets build/debug