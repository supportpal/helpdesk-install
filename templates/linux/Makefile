TEST_IMAGE?=ubuntu:18.04

WORK_DIR="/supportpal"
VOLUME_MOUNTS=-v "$(CURDIR):$(WORK_DIR)"

.PHONY: shellcheck
shellcheck: setup.sh
	docker run --rm \
		$(VOLUME_MOUNTS) \
		-w $(WORK_DIR) \
		koalaman/shellcheck \
		$(addprefix -e, SC1091 SC1117) \
		"$<"

.PHONY: test
test: verify-install.sh
	docker run --rm -i \
		$(VOLUME_MOUNTS) \
		-w $(WORK_DIR) \
		-p 80:80 \
		$(TEST_IMAGE) \
		bash "$<"
