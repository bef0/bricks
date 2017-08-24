build:
	stack build --fast
	stack exec -- site

deploy:
	rsync -avz -e 'ssh -p 36411' out/ web-deploy@chris-martin.org:~/chris-martin.org/

.PHONY: build deploy