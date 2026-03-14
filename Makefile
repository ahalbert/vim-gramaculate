VADER  = ~/.vim/plugged/vader.vim
VADER_OUTPUT ?= /dev/stderr

.PHONY: test

test:
	@test -d $(VADER) || { echo "vader.vim not found at $(VADER). Run: vim -c 'PlugInstall'"; exit 1; }
	vim -u NONE -N --not-a-term \
		-c "set rtp+=$(VADER) rtp+=." \
		-c "runtime plugin/vader.vim" \
		-c "runtime plugin/gramaculate.vim" \
		-c "Vader! test/gramaculate.vader" \
		< /dev/null 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\[[?][0-9;]*[a-zA-Z]//g'
