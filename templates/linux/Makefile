TEST_IMAGE?=ubuntu:16.04

VOLUME_MOUNTS=-v "$(CURDIR)":/v

.PHONY: shellcheck
shellcheck: setup.sh
	docker run --rm \
		$(VOLUME_MOUNTS) \
		-w /v \
		koalaman/shellcheck \
		$(addprefix -e, SC1091 SC1117) \
		"$<"

.PHONY: test
test: verify-install.sh
	docker run --rm -i \
		$(VOLUME_MOUNTS) \
		-w /v \
		-p 80:80 \
		$(TEST_IMAGE) \
		bash "$<"
